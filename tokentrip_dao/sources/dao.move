module tokentrip_dao::dao {
    use sui::object::{Self, ID, UID};
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
    const E_PROPOSAL_NOT_ACTIVE: u64 = 1;
    const E_VOTING_PERIOD_NOT_ENDED: u64 = 2;
    const E_PROPOSAL_ALREADY_EXECUTED: u64 = 3;
    const E_VOTING_CLOSED: u64 = 4;
    const E_ALREADY_VOTED: u64 = 5;
    const E_PROPOSAL_FAILED: u64 = 6;
    const E_INSUFFICIENT_BALANCE_TO_PROPOSE: u64 = 7; // --- AÑADIDO ---

    // --- CONSTANTES ---
    const VOTING_PERIOD_MS: u64 = 604_800_000; // 7 días en ms
    const MINIMUM_TKT_TO_PROPOSE: u64 = 10_000_000_000_000; // --- AÑADIDO --- (10,000 TKT con 9 decimales)

    // --- STRUCTS ---
    public struct DAO has key, store {
        id: UID,
        proposal_count: u64
    }

    public struct DAOTreasury has key, store {
        id: UID,
        balance: Balance<TKT>
    }

    public struct Proposal has key, store {
        id: UID,
        proposal_id: u64,
        creator: address,
        title: StdString,
        description: StdString,
        for_votes: u64,
        against_votes: u64,
        end_timestamp_ms: u64,
        is_executed: bool,
        voters: Table<address, bool>,
        transfer_destination: address,
        transfer_amount: u64
    }

    // --- EVENTOS ---
    public struct ProposalCreated has copy, drop {
        proposal_id: u64,
        creator: address,
        title: StdString,
        end_timestamp_ms: u64
    }
    public struct VotedOnProposal has copy, drop {
        proposal_id: u64,
        voter: address,
        vote_for: bool,
        voting_power: u64,
    }
    public struct ProposalExecuted has copy, drop {
        proposal_id: u64,
        executed_by: address
    }

    // --- FUNCIONES ---
    fun init(ctx: &mut TxContext) {
        let dao = DAO {
            id: object::new(ctx),
            proposal_count: 0
        };
        transfer::share_object(dao);

        let treasury = DAOTreasury {
            id: object::new(ctx),
            balance: balance::zero()
        };
        transfer::share_object(treasury);
    }

    // --- AÑADIDO ---
    /// Permite depositar fondos TKT en la tesorería de la DAO.
    public entry fun deposit_to_treasury(
        treasury: &mut DAOTreasury,
        funds: Coin<TKT>
    ) {
        let incoming_balance = coin::into_balance(funds);
        balance::join(&mut treasury.balance, incoming_balance);
    }

    // --- MODIFICADO ---
    /// Permite a un usuario con suficientes TKT crear una propuesta de gobernanza.
    public entry fun create_proposal(
        dao: &mut DAO,
        tkt_coin: Coin<TKT>, // Se requiere una moneda TKT como "prueba de participación"
        title: vector<u8>,
        description: vector<u8>,
        transfer_destination: address,
        transfer_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);

        assert!(coin::value(&tkt_coin) >= MINIMUM_TKT_TO_PROPOSE, E_INSUFFICIENT_BALANCE_TO_PROPOSE);
        transfer::public_transfer(tkt_coin, sender);

        dao.proposal_count = dao.proposal_count + 1;
        let proposal_id = dao.proposal_count;

        let end_time = clock::timestamp_ms(clock) + VOTING_PERIOD_MS;

        let proposal = Proposal {
            id: object::new(ctx),
            proposal_id,
            creator: sender,
            title: utf8(title),
            description: utf8(description),
            for_votes: 0,
            against_votes: 0,
            end_timestamp_ms: end_time,
            is_executed: false,
            voters: table::new(ctx),
            transfer_destination,
            transfer_amount
        };

        event::emit(ProposalCreated {
            proposal_id,
            creator: sender,
            title: proposal.title,
            end_timestamp_ms: end_time
        });

        transfer::share_object(proposal);
    }
    
    public entry fun execute_proposal(
        proposal: &mut Proposal,
        treasury: &mut DAOTreasury,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(clock::timestamp_ms(clock) >= proposal.end_timestamp_ms, E_VOTING_PERIOD_NOT_ENDED);
        assert!(!proposal.is_executed, E_PROPOSAL_ALREADY_EXECUTED);
        assert!(proposal.for_votes > proposal.against_votes, E_PROPOSAL_FAILED);

        proposal.is_executed = true;

        let amount_to_transfer = proposal.transfer_amount;
        if (amount_to_transfer > 0) {
            let funds = balance::split(&mut treasury.balance, amount_to_transfer);
            let payment = coin::from_balance(funds, ctx);
            transfer::public_transfer(payment, proposal.transfer_destination);
        };

        event::emit(ProposalExecuted {
            proposal_id: proposal.proposal_id,
            executed_by: tx_context::sender(ctx)
        });
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

        if (vote_for) {
            proposal.for_votes = proposal.for_votes + voting_power;
        } else {
            proposal.against_votes = proposal.against_votes + voting_power;
        };
        
        table::add(&mut proposal.voters, voter, true);

        event::emit(VotedOnProposal {
            proposal_id: proposal.proposal_id,
            voter,
            vote_for,
            voting_power
        });
    }
}