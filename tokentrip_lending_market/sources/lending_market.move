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
    const E_WRONG_CURRENCY: u64 = 5;

    // --- CONSTANTES DE COMISIONES ---
    // Comisión que la plataforma cobra sobre el interés del prestamista.
    const LENDER_FEE_BASIS_POINTS: u64 = 1000; // 10%
    const LENDER_VIP_FEE_BASIS_POINTS: u64 = 500; // 5% para VIPs

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
    public struct LoanRequested has copy, drop { request_id: ID, borrower: address, asset_id: ID }
    public struct LoanRequestCancelled has copy, drop { request_id: ID, borrower: address }
    public struct LoanFunded has copy, drop { request_id: ID, loan_id: ID, borrower: address, lender: address }
    public struct LoanRepaid has copy, drop { loan_id: ID, borrower: address, lender: address }
    public struct LoanLiquidated has copy, drop { loan_id: ID, lender: address, asset_id: ID }


    // --- FUNCIONES ---

   // --- FUNCIONES DE CREACIÓN DE SOLICITUDES ---
    public entry fun create_nft_loan_request(nft: ExperienceNFT, principal: u64, repayment: u64, duration: u64, is_tkt: bool, ctx: &mut TxContext) {
        let borrower = tx_context::sender(ctx);
        let asset_id = object::id(&nft);
        let request = LoanRequest {
            id: object::new(ctx),
            nft: option::some(nft),
            fraction: option::none(),
            borrower, principal_amount: principal, repayment_amount: repayment, duration_ms: duration, is_tkt_loan: is_tkt,
        };
        event::emit(LoanRequested { request_id: object::id(&request), borrower, asset_id });
        transfer::share_object(request);
    }

    public entry fun create_fraction_loan_request(fraction: Fraction, principal: u64, repayment: u64, duration: u64, is_tkt: bool, ctx: &mut TxContext) {
        let borrower = tx_context::sender(ctx);
        let asset_id = object::id(&fraction);
        let request = LoanRequest {
            id: object::new(ctx),
            nft: option::none(),
            fraction: option::some(fraction),
            borrower, principal_amount: principal, repayment_amount: repayment, duration_ms: duration, is_tkt_loan: is_tkt,
        };
        event::emit(LoanRequested { request_id: object::id(&request), borrower, asset_id });
        transfer::share_object(request);
    }
    
    /// [PRESTATARIO] Cancela una solicitud de préstamo antes de que sea financiada.
    public entry fun delist_loan_request(request: LoanRequest, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        assert!(sender == request.borrower, E_UNAUTHORIZED);
        
        let request_id = object::id(&request);
        let LoanRequest { id, nft, fraction, borrower, .. } = request;
        
        if (option::is_some(&nft)) {
            transfer::public_transfer(option::destroy_some(nft), borrower);
        } else {
            transfer::public_transfer(option::destroy_some(fraction), borrower);
        };

        event::emit(LoanRequestCancelled { request_id, borrower });
        object::delete(id);
    }

    // --- FUNCIONES DE GESTIÓN DE PRÉSTAMOS ---
    
    /// [PRESTAMISTA] Financia una solicitud de préstamo con SUI.
    public entry fun fund_loan_sui(request: LoanRequest, payment: Coin<SUI>, clock: &Clock, ctx: &mut TxContext) {
        assert!(!request.is_tkt_loan, E_WRONG_CURRENCY);
        fund_loan(request, coin::into_balance(payment), clock, ctx);
    }
    
    /// [PRESTAMISTA] Financia una solicitud de préstamo con TKT.
    public entry fun fund_loan_tkt(request: LoanRequest, payment: Coin<TKT>, clock: &Clock, ctx: &mut TxContext) {
        assert!(request.is_tkt_loan, E_WRONG_CURRENCY);
        fund_loan(request, coin::into_balance(payment), clock, ctx);
    }

    /// [PRESTATARIO] Paga un préstamo en SUI.
    public entry fun repay_loan_sui(loan: ActiveLoan, vip_registry: &VipRegistry, staking_pool: &mut StakingPool, repayment: Coin<SUI>, clock: &Clock, ctx: &mut TxContext) {
        assert!(!loan.is_tkt_loan, E_WRONG_CURRENCY);
        let interest_earned = loan.repayment_amount - loan.principal_amount;
        let mut repayment_balance = coin::into_balance(repayment);

        if (interest_earned > 0) {
            let fee_rate = if (table::contains(&vip_registry.vips, loan.lender)) { LENDER_VIP_FEE_BASIS_POINTS } else { LENDER_FEE_BASIS_POINTS };
            let platform_fee = (interest_earned * fee_rate) / 10000;
            if (platform_fee > 0) {
                let fee_balance = balance::split(&mut repayment_balance, platform_fee);
                staking::deposit_rewards(staking_pool, coin::from_balance(fee_balance, ctx));
            };
        };
        repay_loan(loan, repayment_balance, clock, ctx);
    }
    
    /// [PRESTATARIO] Paga un préstamo en TKT.
    public entry fun repay_loan_tkt(loan: ActiveLoan, vip_registry: &VipRegistry, dao_treasury: &mut DAOTreasury, tkt_cap: &mut TreasuryCap<TKT>, repayment: Coin<TKT>, clock: &Clock, ctx: &mut TxContext) {
        assert!(loan.is_tkt_loan, E_WRONG_CURRENCY);
        let interest_earned = loan.repayment_amount - loan.principal_amount;
        let mut repayment_balance = coin::into_balance(repayment);

        if (interest_earned > 0) {
            let fee_rate = if (table::contains(&vip_registry.vips, loan.lender)) { LENDER_VIP_FEE_BASIS_POINTS } else { LENDER_FEE_BASIS_POINTS };
            let platform_fee = (interest_earned * fee_rate) / 10000;
            if (platform_fee > 0) {
                let mut fee_balance = balance::split(&mut repayment_balance, platform_fee);
                let fee_value = balance::value(&fee_balance);
                let rewards_part = balance::split(&mut fee_balance, fee_value * 40 / 100);
                let dao_part = balance::split(&mut fee_balance, fee_value * 30 / 100);
                
                dao::deposit_to_treasury(dao_treasury, coin::from_balance(rewards_part, ctx));
                dao::deposit_to_treasury(dao_treasury, coin::from_balance(dao_part, ctx));
                coin::burn(tkt_cap, coin::from_balance(fee_balance, ctx));
            };
        };
        repay_loan(loan, repayment_balance, clock, ctx);
    }
    
    /// [PRESTAMISTA] Liquida un préstamo vencido para quedarse con el colateral.
    public entry fun liquidate_loan(loan: ActiveLoan, clock: &Clock, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == loan.lender, E_UNAUTHORIZED);
        assert!(clock::timestamp_ms(clock) > loan.due_timestamp_ms, E_LOAN_NOT_DUE_YET);
        
        let asset_id = if (option::is_some(&loan.nft)) { object::id(option::borrow(&loan.nft)) } else { object::id(option::borrow(&loan.fraction)) };
        let loan_id = object::id(&loan);
        let ActiveLoan { id, nft, fraction, lender, .. } = loan;

        event::emit(LoanLiquidated { loan_id, lender, asset_id });
        
        if (option::is_some(&nft)) {
            transfer::public_transfer(option::destroy_some(nft), lender);
            option::destroy_none(fraction);
        } else {
            transfer::public_transfer(option::destroy_some(fraction), lender);
            option::destroy_none(nft);
        };
        object::delete(id);
    }

    // --- FUNCIONES INTERNAS (PRIVADAS) ---

    fun fund_loan<C>(request: LoanRequest, payment: Balance<C>, clock: &Clock, ctx: &mut TxContext) {
        assert!(balance::value(&payment) >= request.principal_amount, E_INSUFFICIENT_FUNDS);
        let lender = tx_context::sender(ctx);
        let request_id = object::id(&request);
        let LoanRequest { id, nft, fraction, borrower, principal_amount, repayment_amount, duration_ms, is_tkt_loan } = request;
        
        let loan = ActiveLoan {
            id: object::new(ctx), nft, fraction, borrower, lender, principal_amount, repayment_amount,
            due_timestamp_ms: clock::timestamp_ms(clock) + duration_ms, is_tkt_loan,
        };

        event::emit(LoanFunded { request_id, loan_id: object::id(&loan), borrower, lender, principal: principal_amount });
        transfer::public_transfer(coin::from_balance(payment, ctx), borrower);
        transfer::share_object(loan);
        object::delete(id);
    }

    fun repay_loan<C>(loan: ActiveLoan, repayment: Balance<C>, clock: &Clock, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == loan.borrower, E_UNAUTHORIZED);
        assert!(clock::timestamp_ms(clock) <= loan.due_timestamp_ms, E_LOAN_EXPIRED);
        assert!(balance::value(&repayment) >= (loan.repayment_amount - (loan.repayment_amount - loan.principal_amount)), E_INSUFFICIENT_FUNDS);
        
        let loan_id = object::id(&loan);
        let ActiveLoan { id, nft, fraction, borrower, lender, .. } = loan;
        
        event::emit(LoanRepaid { loan_id, borrower, lender, repayment: balance::value(&repayment) });

        transfer::public_transfer(coin::from_balance(repayment, ctx), lender);
        
        if (option::is_some(&nft)) {
            transfer::public_transfer(option::destroy_some(nft), borrower);
            option::destroy_none(fraction);
        } else {
            transfer::public_transfer(option::destroy_some(fraction), borrower);
            option::destroy_none(nft);
        };
        object::delete(id);
    }
}
