module tokentrip_dao::dao {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use std::string::{String as StdString, utf8};
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use tokentrip_token::tkt::TKT;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};

    // --- CÓDIGOS DE ERROR ---
    const E_VOTING_PERIOD_NOT_ENDED: u64 = 1;
    const E_PROPOSAL_ALREADY_EXECUTED: u64 = 2;
    const E_VOTING_CLOSED: u64 = 3;
    const E_ALREADY_VOTED: u64 = 4;
    const E_PROPOSAL_FAILED: u64 = 5;
    const E_INSUFFICIENT_BALANCE_TO_PROPOSE: u64 = 6;
    const E_INVALID_PARAMETER_ID: u64 = 7;
    const E_QUORUM_NOT_REACHED: u64 = 8;

    // --- CONSTANTES DE GOBERNANZA (IDs para los parámetros) ---
    const PARAM_ID_MIN_TO_PROPOSE: u8 = 0;
    const PARAM_ID_VOTING_PERIOD: u8 = 1;
    const PARAM_ID_QUORUM: u8 = 2;
    const PARAM_ID_APPROVAL: u8 = 3;
    const PARAM_ID_TOTAL_SUPPLY: u8 = 4;

    // --- DEFINICIÓN DE ACCIONES ---
    public enum ProposalAction has store, copy, drop {
        TransferTKT { recipient: address, amount: u64 },
        Signal { metadata_url: StdString },
        UpdateDaoParameter { parameter_id: u8, new_value: u64 },
        SignalVipStatusUpdate { provider_address: address, is_vip: bool },
    }

    // --- STRUCTS ---
    public struct DAO has drop {} // Testigo de Un Solo Uso (OTW)

    public struct DaoV1 has key, store { // Objeto de estado principal, renombrado
        id: UID,
        proposal_count: u64,
        min_tkt_to_propose: u64,
        voting_period_ms: u64,
        quorum_percentage: u64,
        approval_percentage: u64,
        total_tkt_supply: u64,
    }

    public struct DAOTreasury has key, store { id: UID, balance: Balance<TKT> }

    public struct Proposal has key, store {
        id: UID, proposal_id: u64, creator: address, title: StdString, description: StdString,
        for_votes: u64, against_votes: u64, end_timestamp_ms: u64, is_executed: bool,
        voters: Table<address, bool>, action: ProposalAction,
    }
    
    // --- EVENTOS (completos) ---
    public struct ProposalCreated has copy, drop { proposal_id: u64, creator: address, title: StdString, end_timestamp_ms: u64 }
    public struct VotedOnProposal has copy, drop { proposal_id: u64, voter: address, vote_for: bool, voting_power: u64 }
    public struct ProposalExecuted has copy, drop { proposal_id: u64, executed_by: address }

    // --- FUNCIONES ---
    fun init(witness: DAO, ctx: &mut TxContext) {
        let dao = DaoV1 {
            id: object::new(ctx), proposal_count: 0,
            min_tkt_to_propose: 10_000_000_000_000, // 10,000 TKT
            voting_period_ms: 604_800_000, // 7 días
            quorum_percentage: 4,
            approval_percentage: 66,
            total_tkt_supply: 0,
        };
        transfer::share_object(dao);
        let treasury = DAOTreasury { id: object::new(ctx), balance: balance::zero() };
        transfer::share_object(treasury);
    }
    
    public entry fun deposit_to_treasury(treasury: &mut DAOTreasury, funds: Coin<TKT>) {
        balance::join(&mut treasury.balance, coin::into_balance(funds));
    }

    // --- SECCIÓN DE CREACIÓN DE PROPUESTAS ---
    // La función genérica 'create_proposal' se ha eliminado.
    // En su lugar, usamos estas funciones de entrada específicas.

    public entry fun create_transfer_proposal(
        dao: &mut DaoV1, tkt_coin: Coin<TKT>, title: vector<u8>, description: vector<u8>,
        recipient: address, amount: u64, clock: &Clock, ctx: &mut TxContext
    ) {
        let action = ProposalAction::TransferTKT { recipient, amount };
        internal_create_proposal(dao, tkt_coin, title, description, action, clock, ctx);
    }

    public entry fun create_signal_proposal(
        dao: &mut DaoV1, tkt_coin: Coin<TKT>, title: vector<u8>, description: vector<u8>,
        metadata_url: vector<u8>, clock: &Clock, ctx: &mut TxContext
    ) {
        let action = ProposalAction::Signal { metadata_url: utf8(metadata_url) };
        internal_create_proposal(dao, tkt_coin, title, description, action, clock, ctx);
    }

    public entry fun create_parameter_update_proposal(
        dao: &mut DaoV1, tkt_coin: Coin<TKT>, title: vector<u8>, description: vector<u8>,
        parameter_id: u8, new_value: u64, clock: &Clock, ctx: &mut TxContext
    ) {
        let action = ProposalAction::UpdateDaoParameter { parameter_id, new_value };
        internal_create_proposal(dao, tkt_coin, title, description, action, clock, ctx);
    }
    
    fun internal_create_proposal(
        dao: &mut DaoV1, tkt_coin: Coin<TKT>, title: vector<u8>,
        description: vector<u8>, action: ProposalAction, clock: &Clock, ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(coin::value(&tkt_coin) >= dao.min_tkt_to_propose, E_INSUFFICIENT_BALANCE_TO_PROPOSE);
        transfer::public_transfer(tkt_coin, sender);
        
        dao.proposal_count = dao.proposal_count + 1;
        let proposal = Proposal {
            id: object::new(ctx), proposal_id: dao.proposal_count, creator: sender,
            title: utf8(title), description: utf8(description),
            for_votes: 0, against_votes: 0, end_timestamp_ms: clock::timestamp_ms(clock) + dao.voting_period_ms,
            is_executed: false, voters: table::new(ctx), action
        };
        // --- CORRECCIÓN: Se completa el evento ---
        event::emit(ProposalCreated { 
            proposal_id: proposal.proposal_id, 
            creator: sender, 
            title: proposal.title, 
            end_timestamp_ms: proposal.end_timestamp_ms 
        });
        transfer::share_object(proposal);
    }

    public entry fun execute_proposal(
        dao: &mut DaoV1, 
        proposal: &mut Proposal, 
        treasury: &mut DAOTreasury,
        clock: &Clock, 
        ctx: &mut TxContext
    ) {
        assert!(clock::timestamp_ms(clock) >= proposal.end_timestamp_ms, E_VOTING_PERIOD_NOT_ENDED);
        assert!(!proposal.is_executed, E_PROPOSAL_ALREADY_EXECUTED);
        assert!(is_approved(proposal, dao), E_PROPOSAL_FAILED);

        proposal.is_executed = true;

        match (proposal.action) {
            ProposalAction::TransferTKT { recipient, amount } => {
                execute_transfer(treasury, recipient, amount, ctx);
            },
            ProposalAction::UpdateDaoParameter { parameter_id, new_value } => {
                execute_update_parameter(dao, parameter_id, new_value);
            },
            // Las otras acciones son señales, no tienen acción on-chain en este módulo
            ProposalAction::Signal { metadata_url: _ } => {},
            ProposalAction::SignalVipStatusUpdate { provider_address: _, is_vip: _ } => {}
        };
        event::emit(ProposalExecuted { proposal_id: proposal.proposal_id, executed_by: tx_context::sender(ctx) });
    }

    public entry fun vote(
        proposal: &mut Proposal, 
        tkt_coin: Coin<TKT>, 
        vote_for: bool, 
        clock: &Clock, 
        ctx: &mut TxContext
    ) {
        let voter = tx_context::sender(ctx);
        assert!(clock::timestamp_ms(clock) < proposal.end_timestamp_ms, E_VOTING_CLOSED);
        assert!(!table::contains(&proposal.voters, voter), E_ALREADY_VOTED);
        
        let voting_power = coin::value(&tkt_coin);
        transfer::public_transfer(tkt_coin, voter);

        if (vote_for) { proposal.for_votes = proposal.for_votes + voting_power; } 
        else { proposal.against_votes = proposal.against_votes + voting_power; };
        
        table::add(&mut proposal.voters, voter, true);
        event::emit(VotedOnProposal { proposal_id: proposal.proposal_id, voter, vote_for, voting_power });
    }
    
    // --- CORRECCIÓN: Se usa DaoV1 consistentemente ---
    public fun is_approved(proposal: &Proposal, dao: &DaoV1): bool {
        let total_votes = proposal.for_votes + proposal.against_votes;
        if (dao.total_tkt_supply == 0) return false;
        let quorum_reached = (total_votes * 100) / dao.total_tkt_supply >= dao.quorum_percentage;
        let approval_reached = if (total_votes > 0) { (proposal.for_votes * 100) / total_votes >= dao.approval_percentage } else { false };
        quorum_reached && approval_reached
    }

    fun execute_transfer(treasury: &mut DAOTreasury, recipient: address, amount: u64, ctx: &mut TxContext) {
        if (amount > 0) {
            let funds = balance::split(&mut treasury.balance, amount);
            transfer::public_transfer(coin::from_balance(funds, ctx), recipient);
        };
    }
    
    // --- CORRECCIÓN: Se usa DaoV1 y se añaden los nuevos parámetros ---
    fun execute_update_parameter(dao: &mut DaoV1, parameter_id: u8, new_value: u64) {
        if (parameter_id == PARAM_ID_MIN_TO_PROPOSE) { dao.min_tkt_to_propose = new_value; }
        else if (parameter_id == PARAM_ID_VOTING_PERIOD) { dao.voting_period_ms = new_value; }
        else if (parameter_id == PARAM_ID_QUORUM) { dao.quorum_percentage = new_value; }
        else if (parameter_id == PARAM_ID_APPROVAL) { dao.approval_percentage = new_value; }
        else if (parameter_id == PARAM_ID_TOTAL_SUPPLY) { dao.total_tkt_supply = new_value; }
        else { abort E_INVALID_PARAMETER_ID };
    }
}