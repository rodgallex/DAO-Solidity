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
   Este contrato gestiona un sistema de votación cuadrática on-chain con soporte para propuestas
   de financiamiento y de signaling. Incorpora medidas de seguridad y eficiencia mediante el patrón
   de diseño “Favor pull over push”, evitando el uso de bucles sobre datos de usuario en funciones críticas.

   Permite:
   • Abrir la votación con un presupuesto inicial en Ether (estado: Closed → Open).
   • Inscribir participantes que compran tokens (usados como votos) a un precio fijo.
   • Permitir que los participantes compren tokens adicionales o vendan los no bloqueados.
   • Registrar propuestas:
        - De financiamiento, si su presupuesto es mayor que 0.
        - De signaling, si el presupuesto es 0.
   • Votar en propuestas mediante la función stake(), con coste cuadrático:
        cost = (votosNuevosTotales)² - (votosAntiguos)²
   • Evaluar si se alcanza el umbral de aprobación (threshold) para ejecutar propuestas de financiamiento,
     calculado como:
        threshold = (0.2 + (presupuesto_i / PresupuestoTotal)) * numParticipantes + numPropuestasPendientes
     utilizando aritmética de punto fijo (SCALING = 1e18).
   • Cancelar propuestas (por su creador) y permitir a los votantes retirar sus votos.
   • Cerrar la votación de forma segura con el patrón pull-over-push:
        - Cambia el estado a ClosedButPending.
        - Permite que los participantes reclamen tokens de forma individual (claimRefund).
        - Permite que cualquiera ejecute propuestas de signaling manualmente (executeSignaling).

   Se incluyen funciones “getter” para acceder a:
   • Las propuestas pendientes, aprobadas y de signaling.
   • Información detallada de cada propuesta individual.
   • Dirección del contrato ERC20 usado como token de voto.
*/

contract QuadraticVoting {
    
    // Dirección del owner (el mismo que abrió el contrato de votación)
    address private owner;
    uint periodo=0;
    
    // Estados del proceso de votación
    enum VotingState { Open, ClosedButPending, Closed }
    VotingState private state;
    
    // Instancia del contrato de tokens para la votación
    VotingToken private  votingToken;
    
    // Precio del token en wei (se establece en el constructor)
    uint public  tokenPrice;
    // Máximo de tokens disponibles para la venta (cap del ERC20)
    uint private maxTokens;
    // Total de tokens vendidos hasta el momento
    uint private tokensSold;
    
    // Presupuesto total en Ether disponible para financiar propuestas
    uint private votingBudget;
    
    // Registro de participantes y cuenta de participantes inscritos
    uint private participantCount;
    mapping(address => bool) private isParticipant;
    
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
        mapping(address => uint) votes;  // Cantidad de votos de cada participante en esta propuesta
        uint indice;
        uint periodo;
    }
    
    // Siguiente id disponible
    uint private nextProposalId;

    // Almacena las propuestas por su id
    mapping(uint => Proposal) private proposals;
    
    // Arrays para llevar registro de propuestas según su estado y tipo
    uint[] private pendingFundingProposals;
    uint[] private canRefundgProposals;
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
    event VotingReset(uint remainingBudget);
    
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
        delete pendingFundingProposals;
        delete signalingProposals;
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
        emit ParticipantAdded(msg.sender, tokensToBuy);
    }
    
    // FUNCION DE COMPRA DE TOKENS: Permite a un participante ya inscrito comprar tokens adicionales.
    function buyTokens() external payable inState(VotingState.Open) {
        require(isParticipant[msg.sender], "No es participante");
        require(msg.value >= tokenPrice, "Enviar al menos precio de un token");
        uint tokensToBuy = msg.value / tokenPrice;
        require(tokensSold + tokensToBuy <= maxTokens, "No hay tokens suficientes");
        tokensSold += tokensToBuy;
        votingToken.newtoken(msg.sender, tokensToBuy);
        emit ParticipantAdded(msg.sender, tokensToBuy);
    }
    
    // FUNCION DE VENTA DE TOKENS: Permite que un participante venda los tokens que no estén bloqueados por votos.
    // Se quema la cantidad de tokens vendidos y se reembolsa en Ether el importe correspondiente.
    function sellTokens(uint tokenAmount) external inState(VotingState.Open) {
        uint available = votingToken.balanceOf(msg.sender);
        require(available >= tokenAmount, "No tiene tokens disponibles para vender");
        tokensSold -= tokenAmount;
        // Se quema la cantidad de tokens del participante. Para ello, el contrato (owner del token)
        // invoca la función burnFromHolder.
        votingToken.burntoken(msg.sender, tokenAmount);
        uint refundAmount = tokenAmount * tokenPrice;
        require(address(this).balance >= refundAmount, "Fondos insuficientes en el contrato");
        (bool success, ) = msg.sender.call{value: refundAmount}("");
        require(success, "Fallo en la transferencia de Ether");
    }
    
    // ELIMINACION DE PARTICIPANTES: Permite a un participante eliminarse; en esta versión se marca el usuario como no participante.
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
        prop.periodo= periodo;
        // Se registra la propuesta en el array correspondiente según su tipo
        if (budget > 0) {
            pendingFundingProposals.push(nextProposalId);
            prop.indice = pendingFundingProposals.length-1;
        } else {
            signalingProposals.push(nextProposalId);
            prop.indice= signalingProposals.length-1;
        }
        emit ProposalAdded(nextProposalId, title);
        nextProposalId++;
        return nextProposalId - 1;
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
        require(periodo == prop.periodo);
        require(!prop.canceled && !prop.approved, "Propuesta no activa");
        uint currentVotes = prop.votes[msg.sender];
        uint newVotes = currentVotes + numVotes;
        // Cálculo del coste adicional (diferencia de cuadrados)
        uint cost = newVotes * newVotes - currentVotes * currentVotes;
        uint available = votingToken.balanceOf(msg.sender);
        require(available >= cost, "No tiene tokens suficientes para votar");
        // Se transfiere la cantidad de tokens desde el votante a este contrato.
        bool transferred = votingToken.transferFrom(msg.sender, address(this), cost);
        require(transferred, "Transferencia de tokens fallida");
        // Si es la primera vez que el participante vota en esta propuesta, se guarda en el array
        prop.votes[msg.sender] = newVotes;
        prop.totalVotes += numVotes;
        prop.totalTokens += cost;
        emit Voted(proposalId, msg.sender, numVotes, cost);
        
        // Si es una propuesta de financiamiento, se evalúa el umbral y se ejecuta, en caso de cumplirse
        if (prop.budget > 0) {
            _checkAndExecuteProposal(proposalId);
        }
    }
    
    // RETIRAR VOTOS: Permite retirar (deshacer) votos depositados en una propuesta, devolviendo la diferencia en tokens.
    // Se recalcula el coste: refund = (costo_original - costo_nuevo) = (v^2 - (v - retirados)^2)
    function withdrawFromProposal(uint proposalId, uint votesToWithdraw) external inState(VotingState.Open) {
        Proposal storage prop = proposals[proposalId];
        require(periodo == prop.periodo);
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
        bool transferred = votingToken.transfer(msg.sender, refundAmount);
        require(transferred, "Error en la devolucion de tokens");
        emit TokensRefunded(msg.sender, refundAmount);
    }
    
    // Función interna para comprobar si una propuesta de financiamiento alcanza el umbral de aprobación y, en 
    // tal caso, ejecutarla (llamando a executeProposal del contrato externo con un límite de 100000 gas).
    // El umbral se calcula usando:
    //   threshold = (0.2 + (presupuesto_propuesta / votingBudget)) * numParticipantes + numPropuestasPendientes
    function _checkAndExecuteProposal(uint proposalId) internal {
        Proposal storage prop = proposals[proposalId];
        require(periodo == prop.periodo);
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
        console.log("umbral:");
        console.log(threshold);
        if (prop.totalVotes >= threshold && votingBudget >= prop.budget) {
            prop.approved = true;
            removeFromArray(pendingFundingProposals,prop.indice);
            approvedFundingProposals.push(proposalId);
            votingBudget = votingBudget - prop.budget + (prop.totalTokens * tokenPrice);
            votingToken.burntoken(msg.sender, prop.totalTokens);
            // Llamada al contrato externo para ejecutar la propuesta, con gas limitado a 100000
            (bool success, ) = prop.executableContract.call{value: prop.budget, gas: 100000}(
                abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", prop.id, prop.totalVotes, prop.totalTokens)
            );
            require(success, "Ejecucion de la propuesta fallida");
            // Se actualiza el presupuesto:
            // Se descuenta el presupuesto ejecutado y se añade el valor en Ether correspondiente a los tokens usados en votos.
            emit ProposalApproved(proposalId);
            // Los tokens usados en la votacion se consideran consumidos y no pueden devolverse.
        }
    }

    //PATRON NUEVO APLICADO

    // CANCELAR PROPUESTA: Modificación en la función cancelProposal para solo cancelar la propuesta
    function cancelProposal(uint proposalId) external inState(VotingState.Open) {
        Proposal storage prop = proposals[proposalId];
        require(periodo == prop.periodo);
        require(msg.sender == prop.creator, "Solo el creador puede cancelar");
        require(!prop.approved, "Propuesta ya aprobada");
        require(!prop.canceled, "Propuesta ya cancelada");

        // Marcar la propuesta como cancelada y sacarla del array
        prop.canceled = true;
        if (prop.budget > 0) {
            removeFromArray(pendingFundingProposals,prop.indice);
            canRefundgProposals.push(proposalId);
            prop.indice = canRefundgProposals.length-1;
        }else{
            removeFromArray(signalingProposals,prop.indice);
            canRefundgProposals.push(proposalId);
            prop.indice = canRefundgProposals.length-1;
        }

        // Emitir evento para notificar la cancelación
        emit ProposalCanceled(proposalId);
    }


    /*
        CIERRE DE LA VOTACIÓN (PULL-OVER-PUSH): Solo el owner puede cerrar la votación.
        En esta versión rediseñada, se establece el estado ClosedButPending para permitir que
        los participantes reclamen manualmente los tokens bloqueados en propuestas canceladas
        o de signaling, y para que las propuestas de signaling sean ejecutadas individualmente.
    */
    function closeVoting() external onlyOwner inState(VotingState.Open) {
        state = VotingState.Closed;
        periodo++;
        // Guarda el presupuesto restante y lo transfiere al owner
        uint remainingBudget = votingBudget;
        votingBudget = 0;
        // Transfiere el presupuesto restante al owner
        (bool sent, ) = owner.call{value: remainingBudget}("");
        require(sent, "Fallo en transferencia de Ether al owner");
        emit VotingClosed(votingBudget);
    }

    /*
        RECLAMAR TOKENS DE VOTACIÓN: Permite a un participante recuperar los tokens utilizados
        en una propuesta, una vez cancelada una propuesta o en caso de una signaling si se termino el periodo de votacion.
        Esto sustituye el reembolso automático en closeVoting por una llamada manual (pull).
    */
    function claimRefund(uint proposalId) external {
        Proposal storage prop = proposals[proposalId];
        if(prop.budget > 0 && periodo == prop.budget){
            require(!prop.approved && prop.canceled);
            uint votes = prop.votes[msg.sender];
            require(votes > 0, "No tienes votos en esta propuesta");

            uint cost = votes * votes;
            prop.votes[msg.sender] = 0;
            prop.totalTokens -= cost;
            if(prop.totalTokens == 0){
                removeFromArray(canRefundgProposals, prop.indice);
            }
            require(votingToken.transfer(msg.sender, cost), "Transferencia fallida");
            emit TokensRefunded(msg.sender, cost);
        }else if(prop.budget > 0 && periodo > prop.budget){
            require(!prop.approved);
            uint votes = prop.votes[msg.sender];
            require(votes > 0, "No tienes votos en esta propuesta");

            uint cost = votes * votes;
            prop.votes[msg.sender] = 0;
            prop.totalTokens -= cost;
            require(votingToken.transfer(msg.sender, cost), "Transferencia fallida");
            emit TokensRefunded(msg.sender, cost);
        }else {
            require(prop.approved || prop.canceled);
            if(prop.canceled){
                require(!prop.approved && prop.canceled);
                uint votes = prop.votes[msg.sender];
                require(votes > 0, "No tienes votos en esta propuesta");

                uint cost = votes * votes;
                prop.votes[msg.sender] = 0;
                prop.totalTokens -= cost;
                if(prop.totalTokens == 0){
                    removeFromArray(canRefundgProposals, prop.indice);
                }
                require(votingToken.transfer(msg.sender, cost), "Transferencia fallida");
                emit TokensRefunded(msg.sender, cost);
            }else{
                 require(!prop.approved && prop.canceled);
                uint votes = prop.votes[msg.sender];
                require(votes > 0, "No tienes votos en esta propuesta");

                uint cost = votes * votes;
                prop.votes[msg.sender] = 0;
                prop.totalTokens -= cost;
                require(votingToken.transfer(msg.sender, cost), "Transferencia fallida");
                emit TokensRefunded(msg.sender, cost);
            }
        }
        
    }

    

    /*
        EJECUCIÓN MANUAL DE PROPUESTA DE SIGNALING: Permite ejecutar propuestas de signaling
        una a una, evitando el uso de bucles internos. Cualquier usuario puede activar la ejecución.
        La propuesta debe estar activa y no haber sido ejecutada previamente.
    */
    function executeSignaling(uint proposalId) external {
        Proposal storage prop = proposals[proposalId];
        require(periodo > prop.periodo);
        require(prop.budget == 0, "No es signaling");
        require(!prop.canceled, "Propuesta cancelada");
        require(!prop.approved, "Ya ejecutada");
        prop.approved = true;
        (bool success, ) = prop.executableContract.call{gas: 100000}(
            abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", prop.id, prop.totalVotes, prop.totalTokens)
        );
        require(success, "Ejecucion fallida");
    }

    
    // Función auxiliar para eliminar un elemento de un array sin mantener el orden
    function removeFromArray(uint[] storage array ,uint indice) internal {
        uint lastId = array[array.length - 1];
        if(lastId != (array.length - 1)){
            array[indice] = lastId;
            proposals[lastId].indice = indice;
        }
        array.pop();
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

    function getcanRefundgProposals() external view inState(VotingState.Open) returns (uint[] memory) {
        return canRefundgProposals;
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
