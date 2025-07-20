module tokentrip_lending_market::lending_market {
    // --- DEPENDENCIAS ---
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};

    // --- IMPORTACIONES DE OTROS MÓDULOS ---
    use tokentrip_experiences::experience_nft::ExperienceNFT;
    // Se importa el tipo de USDC del paquete de Wormhole
    use wormhole_testnet::coin_registry::USDC;

    // --- CÓDIGOS DE ERROR ---
    const E_LOAN_NOT_DUE_YET: u64 = 1;
    const E_LOAN_EXPIRED: u64 = 2;
    const E_UNAUTHORIZED: u64 = 3;
    const E_INSUFFICIENT_FUNDS: u64 = 4;

    // --- STRUCTS ---

    /// Un objeto compartido que representa una solicitud de préstamo P2P.
    /// Contiene el NFT en escrow y los términos deseados por el prestatario.
    public struct LoanRequest has key, store {
        id: UID,
        // --- CORRECCIÓN: Ahora puede guardar un NFT o una Fracción ---
        nft: Option<ExperienceNFT>,
        fraction: Option<Fraction>,
        borrower: address,
        principal_amount: u64,
        repayment_amount: u64,
        duration_ms: u64,
        is_tkt_loan: bool, // Para saber la moneda del préstamo
    }

    /// Un objeto compartido que representa un préstamo activo y financiado.
     public struct ActiveLoan has key, store {
        id: UID,
        // --- CORRECCIÓN: Ahora puede guardar un NFT o una Fracción ---
        nft: Option<ExperienceNFT>,
        fraction: Option<Fraction>,
        borrower: address,
        lender: address,
        repayment_amount: u64,
        due_timestamp_ms: u64,
        is_tkt_loan: bool,
    }

    // --- EVENTOS ---
    public struct LoanRequested has copy, drop { request_id: ID, borrower: address, nft_id: ID }
    public struct LoanFunded has copy, drop { request_id: ID, loan_id: ID, borrower: address, lender: address, principal: u64 }
    public struct LoanRepaid has copy, drop { loan_id: ID, borrower: address, lender: address, repayment: u64 }
    public struct LoanLiquidated has copy, drop { loan_id: ID, lender: address, nft_id: ID }

    // --- FUNCIONES ---

    /// [PRESTATARIO] Crea una nueva solicitud de préstamo, poniendo su NFT en escrow.
    public entry fun create_loan_request(
        nft: ExperienceNFT,
        principal_amount: u64, // Cuánto quiere recibir
        repayment_amount: u64, // Cuánto pagará de vuelta
        duration_ms: u64,
        ctx: &mut TxContext
    ) {
        let borrower = tx_context::sender(ctx);
        let request = LoanRequest {
            id: object::new(ctx),
            nft,
            borrower,
            principal_amount,
            repayment_amount,
            duration_ms,
        };

        event::emit(LoanRequested {
            request_id: object::id(&request),
            borrower,
            nft_id: object::id(&request.nft),
        });

        transfer::share_object(request);
    }

    /// [PRESTAMISTA] Financia una solicitud de préstamo existente.
    public entry fun fund_loan(
        request: LoanRequest,
        payment: Coin<USDC>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(coin::value(&payment) >= request.principal_amount, E_INSUFFICIENT_FUNDS);

        let lender = tx_context::sender(ctx);
        let request_id = object::id(&request);
        let LoanRequest { id, nft, borrower, principal_amount, repayment_amount, duration_ms } = request;
        
        // Se crea el préstamo activo
        let loan = ActiveLoan {
            id: object::new(ctx),
            nft,
            borrower,
            lender,
            repayment_amount,
            due_timestamp_ms: clock::timestamp_ms(clock) + duration_ms,
        };

        event::emit(LoanFunded {
            request_id,
            loan_id: object::id(&loan),
            borrower,
            lender,
            principal: principal_amount
        });

        // Se transfiere el dinero del préstamo al prestatario
        transfer::public_transfer(payment, borrower);
        // Se comparte el nuevo objeto de préstamo activo
        transfer::share_object(loan);
        // Se elimina el objeto de solicitud original
        object::delete(id);
    }

    /// [PRESTATARIO] Paga un préstamo activo para recuperar su NFT.
    public entry fun repay_loan(
        loan: ActiveLoan,
        repayment: Coin<USDC>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == loan.borrower, E_UNAUTHORIZED);
        assert!(clock::timestamp_ms(clock) <= loan.due_timestamp_ms, E_LOAN_EXPIRED);
        assert!(coin::value(&repayment) >= loan.repayment_amount, E_INSUFFICIENT_FUNDS);
        
        let loan_id = object::id(&loan);
        let ActiveLoan { id, nft, borrower, lender, repayment_amount, due_timestamp_ms: _ } = loan;
        
        event::emit(LoanRepaid { loan_id, borrower, lender, repayment: repayment_amount });

        // El pago va al prestamista
        transfer::public_transfer(repayment, lender);
        // El NFT colateral vuelve al prestatario
        transfer::public_transfer(nft, borrower);
        // Se elimina el objeto de préstamo
        object::delete(id);
    }

    /// [PRESTAMISTA] Liquida un préstamo vencido para quedarse con el NFT colateral.
    public entry fun liquidate_loan(
        loan: ActiveLoan,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == loan.lender, E_UNAUTHORIZED);
        assert!(clock::timestamp_ms(clock) > loan.due_timestamp_ms, E_LOAN_NOT_DUE_YET);
        
        let loan_id = object::id(&loan);
        let nft_id = object::id(&loan.nft);
        let ActiveLoan { id, nft, borrower: _, lender, repayment_amount: _, due_timestamp_ms: _ } = loan;

        event::emit(LoanLiquidated { loan_id, lender, nft_id });
        
        // El NFT colateral se transfiere al prestamista
        transfer::public_transfer(nft, lender);
        // Se elimina el objeto de préstamo
        object::delete(id);
    }
}
