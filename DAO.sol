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
        require(totalSupply() + amount <= cap, "Cap maximo excedido");
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
   • Abrir la votación con un presupuesto inicial en Ether.
   • Inscribir participantes que compran tokens (a un precio fijo, tokenPrice).
   • Permitir que participantes compren tokens adicionales o vendan (recuperando el Ether invertido en tokens NO bloqueados).
   • Registrar propuestas (de financiamiento, si tienen presupuesto > 0; o de "signaling", si son presupuesto 0).
   • Permitir el voto en cada propuesta mediante la función stake, donde el coste es cuadrático:
          cost = (votosNuevosTotales)² - (votosAntiguos)²
   • Comprobar, en cada votación, si se alcanza el umbral de aprobación (usando la fórmula
          threshold = (0.2 + (presupuesto_i/PresupuestoTotal)) * numParticipantes + numPropuestasPendientes
     aplicando aritmética de punto fijo) y, en su caso, ejecutar la propuesta de financiamiento,
     transfiriéndole el presupuesto asignado (con un límite de gas de 100000), actualizando el 
     presupuesto (sumando el valor en Ether correspondiente a los tokens usados en la votación).
   • Permitir cancelar propuestas (por el creador) y retirar votos (recuperando la diferencia de tokens).
   • Cerrar la votación: para cancelar todas las propuestas de financiamiento pendientes (devolviendo tokens a 
     los participantes) y ejecutar las propuestas de signaling; finalmente se transfiere el presupuesto no 
     gastado al owner.
   
   Se incluyen funciones “getter” para los arreglos de propuestas (pendientes, aprobadas y de signaling) y
   para recuperar la información asociada a cada propuesta.
*/
contract QuadraticVoting {
    
    // Dirección del owner (el mismo que abrió el contrato de votación)
    address public owner;
    
    // Estados del proceso de votación
    enum VotingState { Open, Closed }
    VotingState public state;
    
    // Instancia del contrato de tokens para la votación
    VotingToken public votingToken;
    
    // Precio del token en wei (se establece en el constructor)
    uint public tokenPrice;
    // Máximo de tokens disponibles para la venta (cap del ERC20)
    uint public maxTokens;
    // Total de tokens vendidos hasta el momento
    uint public tokensSold;
    
    // Presupuesto total en Ether disponible para financiar propuestas
    uint public votingBudget;
    
    // Registro de participantes y cuenta de participantes inscritos
    uint public participantCount;
    mapping(address => bool) public isParticipant;
    
    // Para controlar los tokens que se han bloqueado por haber votado (no pueden venderse)
    mapping(address => uint) public lockedTokens;
    
    // Estructura de una propuesta
    struct Proposal {
        uint id;
        address creator;
        string title;
        string description;
        uint budget;              // Si es mayor que 0, es una propuesta de financiamiento; 0 indica signaling
        address executableContract; // Dirección de un contrato que implemente IExecutableProposal
        uint totalVotes;          // Suma de votos (cada voto incrementa en 1, independientemente del coste)
        uint totalTokens;         // Suma de tokens consumidos en votos (coste cuadrático total)
        bool approved;
        bool canceled;
        address[] voters;         // Lista de participantes que han votado
        // Se registra la cantidad de votos de cada participante en esta propuesta
        mapping(address => uint) votes;
    }
    
    uint public nextProposalId;

    // Almacena las propuestas por su id
    mapping(uint => Proposal) public proposals;
    
    // Arreglos para llevar registro de propuestas según su estado y tipo
    uint[] public pendingFundingProposals;
    uint[] public approvedFundingProposals;
    uint[] public signalingProposals;
    
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
    
    // APERTURA DE LA VOTACION: Solo el owner puede ejecutar openVoting y debe aportar un presupuesto inicial (en Ether)
    function openVoting() external payable onlyOwner inState(VotingState.Closed) {
        require(msg.value > 0, "Se requiere presupuesto inicial");
        votingBudget = msg.value;
        state = VotingState.Open;
        emit VotingOpened(votingBudget);
    }
    
    // INSCRIPCION DE PARTICIPANTES: Se invoca enviando Ether (al menos tokenPrice) para comprar tokens.
    // Si el remitente aún no estaba registrado, se marca como participante.
    // La cantidad de tokens a comprar se calcula dividiendo el Ether enviado por el precio.
    function addParticipant() external payable inState(VotingState.Open) {
        require(msg.value >= tokenPrice, "Debe enviar al menos el precio de un token");
        uint tokensToBuy = msg.value / tokenPrice;
        require(tokensSold + tokensToBuy <= maxTokens, "No hay tokens suficientes disponibles");
        if (!isParticipant[msg.sender]) {
            isParticipant[msg.sender] = true;
            participantCount++;
        }
        tokensSold += tokensToBuy;
        // Se emiten (mint) los tokens al participante
        votingToken.newtoken(msg.sender, tokensToBuy);
        // Se añade el monto recibido al presupuesto global para propuestas
        votingBudget += msg.value;
        emit ParticipantAdded(msg.sender, tokensToBuy);
    }
    
    // Permite a un participante ya inscrito comprar tokens adicionales.
    function buyTokens() external payable inState(VotingState.Open) {
        require(isParticipant[msg.sender], "No es participante");
        require(msg.value >= tokenPrice, "Enviar al menos precio de un token");
        uint tokensToBuy = msg.value / tokenPrice;
        require(tokensSold + tokensToBuy <= maxTokens, "No hay tokens suficientes");
        tokensSold += tokensToBuy;
        votingToken.newtoken(msg.sender, tokensToBuy);
        votingBudget += msg.value;
        emit ParticipantAdded(msg.sender, tokensToBuy);
    }
    
    // FUNCION DE VENTA DE TOKENS: Permite que un participante venda los tokens que no estén bloqueados por votos.
    // Se quema la cantidad de tokens vendidos y se reembolsa en Ether el importe correspondiente.
    function sellTokens(uint tokenAmount) external inState(VotingState.Open) {
        uint available = votingToken.balanceOf(msg.sender) - lockedTokens[msg.sender];
        require(available >= tokenAmount, "No tiene tokens disponibles para vender");
        // Se quema la cantidad de tokens del participante. Para ello, el contrato (owner del token)
        // invoca la función burnFromHolder.
        votingToken.burntoken(msg.sender, tokenAmount);
        tokensSold -= tokenAmount;
        uint refundAmount = tokenAmount * tokenPrice;
        require(address(this).balance >= refundAmount, "Fondos insuficientes en el contrato");
        (bool success, ) = msg.sender.call{value: refundAmount}("");
        require(success, "Fallo en la transferencia de Ether");
    }
    
    // Permite a un participante eliminarse; en esta versión se marca el usuario como no participante.
    // (Los tokens que posea no se reembolsan automáticamente).
    function removeParticipant() external inState(VotingState.Open) {
        require(isParticipant[msg.sender], "No es participante");
        isParticipant[msg.sender] = false;
        participantCount--;
        // Los tokens que tenga el usuario quedan en su cartera.
    }
    
    // ALTA DE PROPUESTA: Cualquier participante puede proponer, siempre que la votación esté abierta.
    // Se proporciona título, descripción, presupuesto (0 para signaling) y la dirección de un contrato 
    // que implemente la interfaz IExecutableProposal. Se devuelve el identificador de la propuesta.
    function addProposal(string calldata title, string calldata description, uint budget, address executableContract) external inState(VotingState.Open) returns (uint) {
        require(isParticipant[msg.sender], "Solo participantes pueden proponer");
        Proposal storage prop = proposals[nextProposalId];
        prop.id = nextProposalId;
        prop.creator = msg.sender;
        prop.title = title;
        prop.description = description;
        prop.budget = budget;
        prop.executableContract = executableContract;
        prop.approved = false;
        prop.canceled = false;
        // Se registra la propuesta en el arreglo correspondiente según su tipo
        if (budget > 0) {
            pendingFundingProposals.push(nextProposalId);
        } else {
            signalingProposals.push(nextProposalId);
        }
        emit ProposalAdded(nextProposalId, title);
        nextProposalId++;
        return nextProposalId - 1;
    }
    
    // CANCELAR PROPUESTA: Solo el creador de la propuesta puede cancelarla (si aún no está aprobada),
    // y se reembolsa a los votantes (se devuelve el coste de los votos).
    function cancelProposal(uint proposalId) external inState(VotingState.Open) {
        Proposal storage prop = proposals[proposalId];
        require(msg.sender == prop.creator, "Solo el creador puede cancelar");
        require(!prop.approved, "Propuesta ya aprobada");
        require(!prop.canceled, "Propuesta ya cancelada");
        prop.canceled = true;
        refundProposalTokens(proposalId);
        if (prop.budget > 0) {
            removeFromArray(pendingFundingProposals, proposalId);
        }
        emit ProposalCanceled(proposalId);
    }
    
    // Función interna para devolver a los votantes los tokens que usaron en una propuesta (en caso de cancelación o cierre)
    function refundProposalTokens(uint proposalId) internal {
        Proposal storage prop = proposals[proposalId];
        for (uint i = 0; i < prop.voters.length; i++) {
            address voter = prop.voters[i];
            uint votesCount = prop.votes[voter];
            if (votesCount > 0) {
                uint cost = votesCount * votesCount; // costo cuadrático
                lockedTokens[voter] -= cost;
                // Se transfieren de vuelta los tokens desde este contrato al votante
                bool sent = votingToken.transfer(voter, cost);
                require(sent, "Error en devolucion de tokens");
                emit TokensRefunded(voter, cost);
                prop.votes[voter] = 0;
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
        require(isParticipant[msg.sender], "No es participante");
        Proposal storage prop = proposals[proposalId];
        require(!prop.canceled && !prop.approved, "Propuesta no activa");
        uint currentVotes = prop.votes[msg.sender];
        uint newVotes = currentVotes + numVotes;
        // Cálculo del coste adicional (diferencia de cuadrados)
        uint cost = newVotes * newVotes - currentVotes * currentVotes;
        uint available = votingToken.balanceOf(msg.sender) - lockedTokens[msg.sender];
        require(available >= cost, "No tiene tokens suficientes para votar");
        // Se transfiere la cantidad de tokens desde el votante a este contrato.
        bool transferred = votingToken.transferFrom(msg.sender, address(this), cost);
        require(transferred, "Transferencia de tokens fallida");
        lockedTokens[msg.sender] += cost;
        // Si es la primera vez que el participante vota en esta propuesta, se guarda en el arreglo
        if (currentVotes == 0) {
            prop.voters.push(msg.sender);
        }
        prop.votes[msg.sender] = newVotes;
        prop.totalVotes += numVotes;
        prop.totalTokens += cost;
        emit Voted(proposalId, msg.sender, numVotes, cost);
        
        // Si es una propuesta de financiamiento, se evalúa el umbral y se ejecuta, en caso de cumplirse
        if (prop.budget > 0) {
            _checkAndExecuteProposal(proposalId);
        }
    }
    
    // Permite retirar (deshacer) votos depositados en una propuesta, devolviendo la diferencia en tokens.
    // Se recalcula el coste: refund = (costo_original - costo_nuevo) = (v^2 - (v - retirados)^2)
    function withdrawFromProposal(uint proposalId, uint votesToWithdraw) external inState(VotingState.Open) {
        Proposal storage prop = proposals[proposalId];
        require(!prop.approved && !prop.canceled, "Propuesta no activa");
        uint currentVotes = prop.votes[msg.sender];
        require(currentVotes >= votesToWithdraw, "No tiene suficientes votos depositados");
        uint remainingVotes = currentVotes - votesToWithdraw;
        uint originalCost = currentVotes * currentVotes;
        uint newCost = remainingVotes * remainingVotes;
        uint refundAmount = originalCost - newCost;
        prop.votes[msg.sender] = remainingVotes;
        prop.totalVotes -= votesToWithdraw;
        prop.totalTokens -= refundAmount;
        lockedTokens[msg.sender] -= refundAmount;
        bool transferred = votingToken.transfer(msg.sender, refundAmount);
        require(transferred, "Error en la devolucion de tokens");
        emit TokensRefunded(msg.sender, refundAmount);
    }
    
    // Función interna para comprobar si una propuesta de financiamiento alcanza el umbral de aprobación y, en 
    // tal caso, ejecutarla (llamando a executeProposal del contrato externo con un límite de 100000 gas).
    // El umbral se calcula usando:
    //   threshold = (0.2 + (presupuesto_propuesta / votingBudget)) * numParticipantes + numPropuestasPendientes
    // (Se usan operaciones con escala fija para incluir el 0.2)
    function _checkAndExecuteProposal(uint proposalId) internal {
        Proposal storage prop = proposals[proposalId];
        if (prop.approved || prop.canceled) {
            return;
        }
        if (prop.budget == 0) {
            return; // No se ejecutan las propuestas de signaling hasta el cierre
        }
        // Se obtiene la cantidad de propuestas de financiamiento pendientes
        uint pendingCount = pendingFundingProposals.length;
        // Se calcula la razón presupuesto/votingBudget con aritmética de punto fijo
        uint ratio = (prop.budget * SCALING) / votingBudget;
        // Se suma 0.2 (es decir, 0.2 * SCALING) y se multiplica por el número de participantes
        uint thresholdScaled = (((2 * SCALING) / 10) + ratio) * participantCount;
        thresholdScaled = thresholdScaled / SCALING;
        // Se añade el número de propuestas pendientes
        uint threshold = thresholdScaled + pendingCount;
        if (prop.totalVotes >= threshold && votingBudget >= prop.budget) {
            prop.approved = true;
            removeFromArray(pendingFundingProposals, proposalId);
            approvedFundingProposals.push(proposalId);
            // Llamada al contrato externo para ejecutar la propuesta, con gas limitado a 100000
            (bool success, ) = prop.executableContract.call{value: prop.budget, gas: 100000}(
                abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", prop.id, prop.totalVotes, prop.totalTokens)
            );
            require(success, "Ejecucion de la propuesta fallida");
            // Se actualiza el presupuesto:
            // Se descuenta el presupuesto ejecutado y se añade el valor en Ether correspondiente a los tokens usados en votos.
            votingBudget = votingBudget - prop.budget + (prop.totalTokens * tokenPrice);
            emit ProposalApproved(proposalId);
            // Los tokens usados en la votacion se consideran consumidos y no pueden devolverse.
        }
    }
    
    // CIERRE DE LA VOTACION: Solo el owner puede cerrar la votación.
    // Durante el cierre:
    // • Se cancelan las propuestas de financiamiento pendientes (reembolsando tokens a los votantes)
    // • Se ejecutan las propuestas de signaling (aunque no se transfiere Ether)
    // • Se transfiere al owner el presupuesto no gastado
    function closeVoting() external onlyOwner inState(VotingState.Open) {
        // Cancelar las propuestas de financiamiento restantes y reembolsar a los votantes
        for (uint i = 0; i < pendingFundingProposals.length; i++) {
            uint proposalId = pendingFundingProposals[i];
            Proposal storage prop = proposals[proposalId];
            if (!prop.canceled) {
                prop.canceled = true;
                refundProposalTokens(proposalId);
                emit ProposalCanceled(proposalId);
            }
        }
        // Ejecutar las propuestas de signaling (con presupuesto cero)
        for (uint i = 0; i < signalingProposals.length; i++) {
            uint proposalId = signalingProposals[i];
            Proposal storage prop = proposals[proposalId];
            if (!prop.canceled) {
                (bool success, ) = prop.executableContract.call{gas: 100000}(
                    abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", prop.id, prop.totalVotes, prop.totalTokens)
                );
                require(success, "Ejecucion de propuesta signaling fallida");
                refundProposalTokens(proposalId);
            }
        }
        uint remainingBudget = votingBudget;
        votingBudget = 0;
        (bool sent, ) = owner.call{value: remainingBudget}("");
        require(sent, "Fallo en transferencia de Ether al owner");
        state = VotingState.Closed;
        emit VotingClosed(remainingBudget);
    }
    
    // Función auxiliar para eliminar un elemento de un arreglo sin mantener el orden
    function removeFromArray(uint[] storage array, uint value) internal {
        for (uint i = 0; i < array.length; i++) {
            if (array[i] == value) {
                array[i] = array[array.length - 1];
                array.pop();
                break;
            }
        }
    }
    
    // Getters para obtener los arreglos de propuestas activos (solo se pueden llamar en estado Open)
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
        return (prop.id, prop.creator, prop.title, prop.description, prop.budget, prop.executableContract, prop.totalVotes, prop.totalTokens, prop.approved, prop.canceled);
    }
    
    // Función para recibir Ether (por ejemplo, para recibir fondos al comprar tokens)
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
