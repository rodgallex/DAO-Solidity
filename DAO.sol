// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/*  
   INTERFAZ PARA EJECUTAR UNA PROPUESTA EXTERNA
   La función executeProposal recibe el id de la propuesta, el número total de votos y la cantidad de tokens 
   (coste total) usados en la votación.
*/
interface IExecutableProposal {
    function executeProposal(uint proposalId, uint numVotes, uint numTokens) external payable;
}

/*
   CONTRATO VotingToken
   Se trata de un token ERC20 (para gestionar la emisión de tokens que se usan en la votación)
   que hereda también de ERC20Burnable para permitir la eliminación de tokens.
   Dado que este contrato se crea desde el contrato principal QuadraticVoting,
   su “owner” será automáticamente el contrato de votación, lo que permite que éste ejecute 
   funciones restringidas (mint y burnFromHolder) sin que cualquier usuario pueda manipular los tokens.
*/
import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract VotingToken is ERC20, ERC20Burnable {
    // El owner será la dirección del contrato de votación
    address public owner;
    // Capacidad máxima de tokens que se pueden poner a la venta
    uint public cap;

    constructor(string memory _name, string memory _symbol, uint _cap) ERC20(_name, _symbol) {
        owner = msg.sender; // msg.sender es el contrato QuadraticVoting que crea este token
        cap = _cap;     
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Solo el owner puede ejecutar esta funcion");
        _;
    }
    
    // Función para crear tokens para un usuario. Solo el contrato de votacion (owner) puede llamar a esta función.
    function newtoken(address to, uint amount) external onlyOwner {
        require(totalSupply() + amount <= cap, "Capacidad maxima de tokens excedida");
        _mint(to, amount);
    }
    
    // Función para quemar tokens de un usuario. Solo el contrato de votacion (owner) puede llamar a esta función.
    function burntoken(address account, uint amount) external onlyOwner {
        _burn(account, amount);
    }
}


/*
   CONTRATO QuadraticVoting
   Este contrato gestiona el proceso de votacion on-chain.
   Permite:
   • Abrir la votación con un presupuesto inicial.
   • Inscribir participantes que compran tokens.
   • Permitir que participantes compren tokens adicionales o vendan.
   • Registrar propuestas (de financiamiento, si tienen presupuesto > 0; o de "signaling", si son presupuesto 0).
   • Permitir el voto en cada propuesta mediante la función stake, donde el coste es cuadrático:
          cost = (votosNuevosTotales)² - (votosAntiguos)²
   • Comprobar, en cada votación, si se alcanza el umbral de aprobación (usando la fórmula
          threshold = (0.2 + (presupuesto_i/PresupuestoTotal)) * numParticipantes + numPropuestasPendientes
     aplicando aritmética de punto fijo) y, en su caso, ejecutar la propuesta de financiamiento,
     transfiriéndole el presupuesto asignado (con un límite de gas de 100000), actualizando el 
     presupuesto (sumando el valor correspondiente a los tokens usados en la votación).
   • Permitir cancelar propuestas y retirar votos.
   • Cerrar la votación: para cancelar todas las propuestas de financiamiento pendientes (devolviendo tokens a 
     los participantes) y ejecutar las propuestas de signaling; finalmente se transfiere el presupuesto no 
     gastado al owner.
   
   Se incluyen funciones “getter” para acceder a:
   • Las propuestas pendientes, aprobadas y de signaling.
   • Información detallada de cada propuesta individual.
   • Dirección del contrato ERC20 usado como token de voto.
*/
contract QuadraticVoting {
    
    // Dirección del owner (el mismo que abrió el contrato de votación)
    address private owner;
    
    // Estados del proceso de votación
    enum VotingState { Open, Closed }
    VotingState private state;
    
    // Instancia del contrato de tokens para la votación
    VotingToken private  votingToken;
    
    // Precio del token en wei (se establece en el constructor)
    uint public tokenPrice;
    // Máximo de tokens disponibles para la venta (cap del ERC20)
    uint private maxTokens;
    // Total de tokens vendidos hasta el momento
    uint private tokensSold;
    
    // Presupuesto total disponible para financiar propuestas
    uint private votingBudget;
    
    // Registro de participantes y cuenta de participantes inscritos
    uint private participantCount;
    mapping(address => bool) private isParticipant;
    
    // Para controlar los tokens que se han bloqueado por haber votado (no pueden venderse)
    mapping(address => uint) private lockedTokens;
    
    // Estructura de una propuesta
    struct Proposal {
        uint id;
        address creator;
        string title;
        string description;
        uint budget;                // Si es mayor que 0, es una propuesta de financiamiento; 0 indica signaling
        address executableContract; // Dirección de un contrato que implemente IExecutableProposal
        uint totalVotes;            // Suma de votos (cada voto incrementa en 1, independientemente del coste)
        uint totalTokens;           // Suma de tokens consumidos en votos (coste cuadrático total)
        bool approved;
        bool canceled;
        address[] voters;           // Lista de participantes que han votado
        mapping(address => uint) votes;  // Cantidad de votos de cada participante en esta propuesta
        
    }
    
    // Siguiente id disponible
    uint private nextProposalId;

    // Almacena las propuestas por su id
    mapping(uint => Proposal) private proposals;
    
    // Arrays para llevar registro de propuestas según su estado y tipo
    uint[] private pendingFundingProposals;
    uint[] private approvedFundingProposals;
    uint[] private signalingProposals;
    
    // Constante para aritmética de punto fijo (para los cálculos de umbral)
    uint constant SCALING = 1e18;
    
    // Eventos para facilitar la trazabilidad
    event VotingOpened(uint initialBudget);
    event ParticipantAdded(address participant, uint tokensBought);
    event ProposalAdded(uint proposalId, string title);
    event Voted(uint proposalId, address voter, uint votes, uint tokensSpent);
    event ProposalApproved(uint proposalId);
    event ProposalCanceled(uint proposalId);
    event TokensRefunded(address participant, uint tokensRefunded);
    event VotingClosed(uint remainingBudget);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "No es el owner");
        _;
    }
    
    modifier inState(VotingState _state) {
        require(state == _state, "Estado no permitido para esta operacion");
        _;
    }
    
    constructor(uint _tokenPrice, uint _maxTokens, string memory tokenName, string memory tokenSymbol) {
        owner = msg.sender;
        tokenPrice = _tokenPrice;
        maxTokens = _maxTokens;
        tokensSold = 0;
        state = VotingState.Closed;
        // Se despliega el contrato del token. Como se crea desde este constructor,
        // el owner del token será este contrato (lo que permite controlarlo internamente).
        votingToken = new VotingToken(tokenName, tokenSymbol, _maxTokens);
    }
    
    // APERTURA DE LA VOTACION: Solo el owner puede ejecutar openVoting y debe aportar un presupuesto inicial
    function openVoting() external payable onlyOwner inState(VotingState.Closed) {
        require(msg.value > 0, "Se requiere presupuesto inicial");
        votingBudget = msg.value;
        state = VotingState.Open;
        emit VotingOpened(votingBudget);
    }
    
    // INSCRIPCION DE PARTICIPANTES: Se invoca enviando la cantidad de al menos un tokenPrice para comprar tokens.
    // Si el remitente aún no estaba registrado, se marca como participante.
    // La cantidad de tokens a comprar se calcula dividiendo el Ether enviado por el precio.
    function addParticipant() external payable inState(VotingState.Open) {
        // Requiere que el participante envíe al menos el valor de un token
        require(msg.value >= tokenPrice, "Debe enviar al menos el precio de un token");
        // Calcula cuántos tokens puede comprar el participante
        uint tokensToBuy = msg.value / tokenPrice;
        // Verifica que no se supere el límite máximo de tokens disponibles
        require(tokensSold + tokensToBuy <= maxTokens, "No hay tokens suficientes disponibles");
        // Si el participante no está registrado, se marca como tal y se incrementa el contador de participantes
        if (!isParticipant[msg.sender]) {
            isParticipant[msg.sender] = true;
            participantCount++;
        }
        // Actualiza la cantidad de tokens vendidos
        tokensSold += tokensToBuy;
        // Emite los tokens al participante utilizando la función del contrato VotingToken
        votingToken.newtoken(msg.sender, tokensToBuy);
        // Añade el monto recibido al presupuesto global de votación
        votingBudget += msg.value;
        // Emite un evento indicando que el participante ha sido agregado con la cantidad de tokens comprados
        emit ParticipantAdded(msg.sender, tokensToBuy);
    }
    
    // FUNCION DE COMPRA DE TOKENS: Permite a un participante ya inscrito comprar tokens adicionales.
    function buyTokens() external payable inState(VotingState.Open) {
        // Requiere que el remitente sea un participante registrado
        require(isParticipant[msg.sender], "No es participante");
        // Verifica que se haya enviado al menos el precio de un token
        require(msg.value >= tokenPrice, "Enviar al menos precio de un token");
        // Calcula la cantidad de tokens a comprar con el Ether enviado
        uint tokensToBuy = msg.value / tokenPrice;
        // Verifica que no se exceda el límite máximo de tokens vendidos
        require(tokensSold + tokensToBuy <= maxTokens, "No hay tokens suficientes");
        // Actualiza el total de tokens vendidos
        tokensSold += tokensToBuy;
        // Emite los tokens al participante usando la función del contrato VotingToken
        votingToken.newtoken(msg.sender, tokensToBuy);
        // Añade el valor al presupuesto global de votación
        votingBudget += msg.value;
        // Emite un evento para indicar que un participante ha comprado tokens adicionales
        emit ParticipantAdded(msg.sender, tokensToBuy);
    }
    
    // FUNCION DE VENTA DE TOKENS: Permite que un participante venda los tokens que no estén bloqueados por votos.
    // Se quema la cantidad de tokens vendidos y se reembolsa el importe correspondiente.
    function sellTokens(uint tokenAmount) external inState(VotingState.Open) {
        // Verifica la cantidad de tokens disponibles para la venta (los tokens bloqueados por votos no cuentan).
        uint available = votingToken.balanceOf(msg.sender) - lockedTokens[msg.sender];
        require(available >= tokenAmount, "No tiene tokens disponibles para vender");
        // Actualiza el total de tokens vendidos (decrementando la cantidad vendida).
        tokensSold -= tokenAmount;
        // Quema la cantidad de tokens que el participante está vendiendo. El contrato tiene permisos para hacer esto.
        votingToken.burntoken(msg.sender, tokenAmount);
        // Calcula el importe que se va a reembolsar al participante (cantidad de tokens vendida * precio de un token).
        uint refundAmount = tokenAmount * tokenPrice;
        // Verifica que el contrato tenga suficientes fondos para realizar la devolución.
        require(address(this).balance >= refundAmount, "Fondos insuficientes en el contrato");
        // Realiza la transferencia al participante.
        (bool success, ) = msg.sender.call{value: refundAmount}("");
        require(success, "Fallo en la transferencia");
    }
    
    // ELIMINACION DE PARTICIPANTES: Permite a un participante eliminarse; en esta versión se marca el usuario como no participante.
    // (Los tokens que posea no se reembolsan automáticamente).
    function removeParticipant() external inState(VotingState.Open) {
        // Verifica si el participante está registrado.
        require(isParticipant[msg.sender], "No es participante");
        // Marca al participante como no registrado.
        isParticipant[msg.sender] = false;
        // Decrementa el contador de participantes.
        participantCount--;
        // Los tokens del participante no se reembolsan automáticamente (quedan en su cartera).
    }
    
    // ALTA DE PROPUESTA: Cualquier participante puede proponer, siempre que la votación esté abierta.
    // Se proporciona título, descripción, presupuesto (0 para signaling) y la dirección de un contrato 
    // que implemente la interfaz IExecutableProposal. Se devuelve el identificador de la propuesta.
    function addProposal(string calldata title, string calldata description, uint budget, address executableContract) external inState(VotingState.Open) returns (uint) {
        // Verifica que solo los participantes puedan proponer una nueva propuesta
        require(isParticipant[msg.sender], "Solo participantes pueden proponer");
        // Registra la propuesta en la estructura Proposal
        Proposal storage prop = proposals[nextProposalId];
        prop.id = nextProposalId;
        prop.creator = msg.sender;
        prop.title = title;
        prop.description = description;
        prop.budget = budget;
        prop.executableContract = executableContract;
        prop.approved = false;
        prop.canceled = false;
        // Se registra la propuesta en el array correspondiente según su tipo
        if (budget > 0) {
            pendingFundingProposals.push(nextProposalId); // Añade la propuesta al listado de financiamiento pendiente
        } else {
            signalingProposals.push(nextProposalId);// Añade la propuesta al listado de signaling
        }
        // Emite un evento para registrar la propuesta añadida
        emit ProposalAdded(nextProposalId, title);
        // Incrementa el ID de la siguiente propuesta
        nextProposalId++;
        // Devuelve el ID de la propuesta recién creada
        return nextProposalId - 1;
    }
    
    // CANCELAR PROPUESTA: Solo el creador de la propuesta puede cancelarla (si aún no está aprobada),
    // y se reembolsa a los votantes (se devuelve el coste de los votos).
    function cancelProposal(uint proposalId) external inState(VotingState.Open) {
        // Obtiene la propuesta correspondiente al ID proporcionado.
        Proposal storage prop = proposals[proposalId];
        // Verifica que el que solicita la cancelación sea el creador de la propuesta.
        require(msg.sender == prop.creator, "Solo el creador puede cancelar");
        // Verifica que la propuesta no haya sido aprobada ya (no se puede cancelar si ha sido aprobada).
        require(!prop.approved, "Propuesta ya aprobada");
        // Verifica que la propuesta no haya sido cancelada previamente.
        require(!prop.canceled, "Propuesta ya cancelada");
        // Marca la propuesta como cancelada.
        prop.canceled = true;
        // Llama a la función que reembolsa los tokens a los votantes de la propuesta cancelada.
        refundProposalTokens(proposalId);
        // Si la propuesta es una propuesta de financiamiento, 
        // se elimina del listado de propuestas de financiamiento pendientes.
        if (prop.budget > 0) {
            removeFromArray(pendingFundingProposals, proposalId);
        }else{
            removeFromArray(signalingProposals, proposalId);
        }
        // Emite un evento para notificar que la propuesta ha sido cancelada.
        emit ProposalCanceled(proposalId);
    }
    
    // Función interna para devolver a los votantes los tokens que usaron en una propuesta (en caso de cancelación o cierre)
    function refundProposalTokens(uint proposalId) internal {
        // Obtiene la propuesta correspondiente al ID proporcionado.
        Proposal storage prop = proposals[proposalId];
        // Recorre todos los votantes que participaron en esta propuesta.
        for (uint i = 0; i < prop.voters.length; i++) {
            address voter = prop.voters[i];
            uint votesCount = prop.votes[voter];
            // Verifica que el votante haya participado en la propuesta
            if (votesCount > 0) {
                uint cost = votesCount * votesCount; // costo cuadrático
                // Desbloquea los tokens que fueron bloqueados para la propuesta cancelada.
                lockedTokens[voter] -= cost;
                prop.votes[voter] = 0;
                // Se transfieren de vuelta los tokens desde este contrato al votante
                bool sent = votingToken.transfer(voter, cost);
                require(sent, "Error en devolucion de tokens");
                // Emite un evento notificando que los tokens han sido reembolsados al votante
                emit TokensRefunded(voter, cost);
            }
        }
    }
    
    // STAKE (depositar votos): El participante deposita votos en una propuesta.
    // El coste adicional se calcula como: (votos_nuevos_total² - votos_previos²).
    // Se transfiere la cantidad de tokens correspondiente (previa aprobación del token) y se 
    // actualizan los registros en la propuesta.
    // Si se trata de una propuesta de financiamiento (budget > 0), se invoca la función interna
    // _checkAndExecuteProposal para determinar si se alcanza el umbral y se ejecuta la propuesta.
    function stake(uint proposalId, uint numVotes) external inState(VotingState.Open) {
        // Verifica que el remitente sea un participante registrado
        require(isParticipant[msg.sender], "No es participante");
        // Obtiene la propuesta correspondiente al ID proporcionado
        Proposal storage prop = proposals[proposalId];
        // Verifica que la propuesta no haya sido cancelada ni aprobada
        require(!prop.canceled && !prop.approved, "Propuesta no activa");
        // Obtiene el número actual de votos del participante en esta propuesta
        uint currentVotes = prop.votes[msg.sender];
        // Calcula el número total de votos después de agregar los nuevos votos
        uint newVotes = currentVotes + numVotes;
        // Calcula el coste adicional de los votos como la diferencia entre los cuadrados de los votos nuevos y los anteriores
        uint cost = newVotes * newVotes - currentVotes * currentVotes;
        // Verifica que el participante tenga suficientes tokens disponibles para votar
        uint available = votingToken.balanceOf(msg.sender) - lockedTokens[msg.sender];
        require(available >= cost, "No tiene tokens suficientes para votar");
        // Transfiere los tokens desde el votante al contrato
        bool transferred = votingToken.transferFrom(msg.sender, address(this), cost);
        require(transferred, "Transferencia de tokens fallida");
        // Actualiza el número de tokens bloqueados por el votante
        lockedTokens[msg.sender] += cost;
        // Si es la primera vez que el participante vota en esta propuesta, se guarda en el array de votantes
        if (currentVotes == 0) {
            prop.voters.push(msg.sender);
        }
        // Actualiza el número de votos del participante en la propuesta
        prop.votes[msg.sender] = newVotes;
        // Actualiza el total de votos y tokens de la propuesta
        prop.totalVotes += numVotes;
        prop.totalTokens += cost;
        // Emite un evento para registrar el voto del participante
        emit Voted(proposalId, msg.sender, numVotes, cost);
        // Si la propuesta tiene presupuesto, evalúa si se alcanza el umbral y ejecuta la propuesta, en caso de cumplirse
        if (prop.budget > 0) {
            _checkAndExecuteProposal(proposalId);
        }
    }
    
    // RETIRAR VOTOS: Permite retirar (deshacer) votos depositados en una propuesta, devolviendo la diferencia en tokens.
    // Se recalcula el coste: refund = (costo_original - costo_nuevo) = (v^2 - (v - retirados)^2)
    function withdrawFromProposal(uint proposalId, uint votesToWithdraw) external inState(VotingState.Open) {
        // Obtiene la propuesta correspondiente al ID proporcionado.
        Proposal storage prop = proposals[proposalId];
        // Verifica que la propuesta no haya sido cancelada ni aprobada.
        require(!prop.approved && !prop.canceled, "Propuesta no activa");
        // Obtiene el número de votos actuales del participante en esta propuesta.
        uint currentVotes = prop.votes[msg.sender];
        // Verifica que el participante tenga suficientes votos depositados para retirar.
        require(currentVotes >= votesToWithdraw, "No tiene suficientes votos depositados");
        // Calcula el número de votos restantes después de la retirada.
        uint remainingVotes = currentVotes - votesToWithdraw;
        // Calcula el costo original de los votos antes de la retirada (v^2).
        uint originalCost = currentVotes * currentVotes;
        // Calcula el nuevo costo después de la retirada (v^2).
        uint newCost = remainingVotes * remainingVotes;
        // Calcula la diferencia entre el costo original y el nuevo costo para determinar el monto a reembolsar.
        uint refundAmount = originalCost - newCost;
        // Actualiza el número de votos del participante para reflejar la retirada.
        prop.votes[msg.sender] = remainingVotes;
        // Actualiza el total de votos y tokens de la propuesta.
        prop.totalVotes -= votesToWithdraw;
        prop.totalTokens -= refundAmount;
        // Desbloquea los tokens que fueron bloqueados para la propuesta.
        lockedTokens[msg.sender] -= refundAmount;
        // Transfiere los tokens de vuelta al participante.
        bool transferred = votingToken.transfer(msg.sender, refundAmount);
        require(transferred, "Error en la devolucion de tokens");
        // Emite un evento notificando que los tokens han sido reembolsados al participante.
        emit TokensRefunded(msg.sender, refundAmount);
    }
    
    // Función interna para comprobar si una propuesta de financiamiento alcanza el umbral de aprobación y, en 
    // tal caso, ejecutarla (llamando a executeProposal del contrato externo con un límite de 100000 gas).
    // El umbral se calcula usando:
    //   threshold = (0.2 + (presupuesto_propuesta / votingBudget)) * numParticipantes + numPropuestasPendientes
    function _checkAndExecuteProposal(uint proposalId) internal {
        // Accede a la propuesta correspondiente al ID proporcionado.
        Proposal storage prop = proposals[proposalId];
        // Si la propuesta ya ha sido aprobada o cancelada, no se hace nada.
        if (prop.approved || prop.canceled) {
            return;
        }
        // Si el presupuesto de la propuesta es cero, no se ejecuta la propuesta de signaling hasta el cierre.
        if (prop.budget == 0) {
            return; // No se ejecutan las propuestas de signaling hasta el cierre
        }
        // Obtiene el número de propuestas de financiamiento pendientes.
        uint pendingCount = pendingFundingProposals.length;
        // Calcula la razón presupuesto/votingBudget utilizando aritmética de punto fijo.
        uint ratio = (prop.budget * SCALING) / votingBudget;
        // Se suma 0.2 (es decir, 0.2 * SCALING) y se multiplica por el número de participantes.
        uint thresholdScaled = (((2 * SCALING) / 10) + ratio) * participantCount;
        thresholdScaled = thresholdScaled / SCALING;
        // Añade el número de propuestas pendientes al umbral.
        uint threshold = thresholdScaled + pendingCount;
        console.log("umbral:");
        console.log(threshold);
        // Si el total de votos es mayor o igual al umbral y el presupuesto es suficiente, se aprueba la propuesta.
        if (prop.totalVotes >= threshold && votingBudget >= prop.budget) {
            prop.approved = true;
            // Elimina la propuesta de la lista de propuestas pendientes de financiamiento.
            removeFromArray(pendingFundingProposals, proposalId);
            // Añade la propuesta a la lista de propuestas aprobadas.
            approvedFundingProposals.push(proposalId);
            // Actualiza el presupuesto global restando el presupuesto de la propuesta y sumando el valor de los tokens utilizados.
            votingBudget = votingBudget - prop.budget + (prop.totalTokens * tokenPrice);
            // Llama al contrato externo para ejecutar la propuesta, con gas limitado a 100000.
            (bool success, ) = prop.executableContract.call{value: prop.budget, gas: 100000}(
                abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", prop.id, prop.totalVotes, prop.totalTokens)
            );
            // Si la ejecución de la propuesta falla, revierte la transacción.
            require(success, "Ejecucion de la propuesta fallida");
            // Emite un evento notificando que la propuesta ha sido aprobada.
            emit ProposalApproved(proposalId);
            // Los tokens utilizados en la votación se consideran consumidos y no pueden devolverse.
        }
    }

    
    // CIERRE DE LA VOTACION: Solo el owner puede cerrar la votación.
    // Durante el cierre:
    // • Se cancelan las propuestas de financiamiento pendientes (reembolsando tokens a los votantes)
    // • Se ejecutan las propuestas de signaling
    // • Se transfiere al owner el presupuesto no gastado
    function closeVoting() external onlyOwner inState(VotingState.Open) {
        // Cancelar las propuestas de financiamiento restantes y reembolsar a los votantes
        for (uint i = pendingFundingProposals.length; i > 0; i--) {
            uint proposalId = pendingFundingProposals[i - 1];
            Proposal storage prop = proposals[proposalId];

            // Verifica si la propuesta no ha sido cancelada aún
            if (!prop.canceled) {
                prop.canceled = true;
                // Reembolsa los tokens a los votantes de la propuesta
                refundProposalTokens(proposalId);
                // Elimina la propuesta de la lista de propuestas pendientes
                removeFromArray(pendingFundingProposals, proposalId);
                // Emite un evento notificando la cancelación de la propuesta
                emit ProposalCanceled(proposalId);
            }
        }

        // Ejecutar las propuestas de signaling (con presupuesto cero)
        for (uint i = signalingProposals.length; i > 0; i--) {
            uint proposalId = signalingProposals[i - 1];
            Proposal storage prop = proposals[proposalId];

            // Verifica si la propuesta no ha sido cancelada aún
            if (!prop.canceled) {
                // Llama al contrato externo para ejecutar la propuesta de signaling
                (bool success, ) = prop.executableContract.call{gas: 100000}(
                    abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", prop.id, prop.totalVotes, prop.totalTokens)
                );
                // Si la ejecución falla, revierte la transacción
                require(success, "Ejecucion de propuesta signaling fallida");

                // Reembolsa los tokens a los votantes
                refundProposalTokens(proposalId);
                // Marca la propuesta como aprobada
                prop.approved = true;
                // Elimina la propuesta de la lista de propuestas de signaling
                removeFromArray(signalingProposals, proposalId);
            }
        }
        // Cambia el estado de la votación a Closed
        state = VotingState.Closed;

        // Guarda el presupuesto restante y lo transfiere al owner
        uint remainingBudget = votingBudget;
        votingBudget = 0;
        // Transfiere el presupuesto restante al owner
        (bool sent, ) = owner.call{value: remainingBudget}("");
        require(sent, "Fallo en transferencia al owner");

        // Emite un evento notificando el cierre de la votación
        emit VotingClosed(remainingBudget);
    }
    
    // Función auxiliar para eliminar un elemento de un array sin mantener el orden
    function removeFromArray(uint[] storage array, uint value) internal {
        for (uint i = 0; i < array.length; i++) {
            if (array[i] == value) {
                array[i] = array[array.length - 1];
                array.pop();
                break;
            }
        }
    }
    
    // Getters para obtener los arrays de propuestas activos (solo se pueden llamar en estado Open)
    function getPendingFundingProposals() external view inState(VotingState.Open) returns (uint[] memory) {
        return pendingFundingProposals;
    }
    
    function getApprovedFundingProposals() external view inState(VotingState.Open) returns (uint[] memory) {
        return approvedFundingProposals;
    }
    
    function getSignalingProposals() external view inState(VotingState.Open) returns (uint[] memory) {
        return signalingProposals;
    }
    
    // Permite obtener la información detallada de una propuesta (solo si la votación está abierta)
    function getProposalInfo(uint proposalId) external view inState(VotingState.Open) returns (
        uint id,
        address creator,
        string memory title,
        string memory description,
        uint budget,
        address executableContract,
        uint totalVotes,
        uint totalTokens,
        bool approved,
        bool canceled
    ) {
        Proposal storage prop = proposals[proposalId];
        // Se usa el storage que es una única referencia a la pila, en vez de acceder directamente (proposals[proposalId].id)
        // para evitar el error de call Stack too deep
        return (prop.id, prop.creator, prop.title, prop.description, prop.budget, prop.executableContract, prop.totalVotes, prop.totalTokens, prop.approved, prop.canceled);
    }

    // Devuelve la dirección del contrato ERC20 usado para los votos
    function getERC20() external view returns (address) {
        return address(votingToken);
    }

    
    // Función para recibir Ether
    receive() external payable {}
}
  
/*
   CONTRATO TestExecutableProposal
   Este contrato es un ejemplo simple que implementa la interfaz IExecutableProposal.
   Su función executeProposal simplemente emite un evento con los datos recibidos, de forma que se 
   pueda verificar la ejecución de la propuesta.
*/
contract TestExecutableProposal is IExecutableProposal {
    event Executed(uint proposalId, uint numVotes, uint numTokens, uint valueReceived, uint contractBalance);
    
    function executeProposal(uint proposalId, uint numVotes, uint numTokens) external payable override {
        emit Executed(proposalId, numVotes, numTokens, msg.value, address(this).balance);
    }
}
