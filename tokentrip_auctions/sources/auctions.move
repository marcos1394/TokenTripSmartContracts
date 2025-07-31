module tokentrip_auctions::auctions {
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::sui::SUI;
    use std::option::{Self, Option};
    use std::type_name;
    use sui::balance::{Self, Balance};
    use tokentrip_experience::experience_nft::{Self, ExperienceNFT};
    use tokentrip_dao::dao::{DAOTreasury, deposit_to_treasury};
    use tokentrip_token::tkt::TKT;
    use sui::coin::{TreasuryCap as TktTreasuryCap}; // Se importa de 'sui::coin' y se le da un alias
    // --- ERRORES ---
    const E_AUCTION_NOT_OVER: u64 = 1;
    const E_AUCTION_ALREADY_SETTLED: u64 = 2;
    const E_BID_TOO_LOW: u64 = 3;
    const E_AUCTION_HAS_ENDED: u64 = 4;
    const E_CANNOT_BID_ON_OWN_AUCTION: u64 = 5;
    const E_RESERVE_PRICE_NOT_MET: u64 = 6;
    const E_WRONG_COIN_TYPE: u64 = 7;
    const PLATFORM_FEE_BASIS_POINTS: u64 = 500; // 5.00%
    const ANTI_SNIPE_EXTENSION_MS: u64 = 300_000; // 5 minutos
    // --- STRUCTS ---
    public struct AUCTIONS has drop {} // Testigo de un solo uso
/// Objeto compartido que representa una subasta activa
public struct Auction has key, store {
    id: UID,
    nft: Option<ExperienceNFT>,
    seller: address,
    is_tkt_auction: bool,
    reserve_price: u64,
    start_price: u64,
    highest_bid: u64,
    highest_bidder: Option<address>,
    bid_vault: Balance<SUI>,
    tkt_bid_vault: Balance<TKT>,
    end_timestamp_ms: u64,
    is_settled: bool,
    }
    // --- EVENTOS ---
public struct AuctionCreated has copy, drop { auction_id: ID, nft_id: ID, seller: address, end_time: u64, is_tkt_auction: bool }
public struct BidPlaced has copy, drop { auction_id: ID, bidder: address, amount: u64 }
public struct AuctionSettled has copy, drop { auction_id: ID, winner: Option<address>, final_price: u64 }
/// Inicia una nueva subasta para un ExperienceNFT
public entry fun create_auction(
    nft: ExperienceNFT,
    start_price_mist: u64,
    reserve_price_mist: u64, // <-- AÑADIDO
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext 
    ) {
 // --- AÑADIDO: Verificación de Expiración ---
        
        assert!(experience_nft::expiration_timestamp_ms(&nft) == 0 || clock::timestamp_ms(clock) < experience_nft::expiration_timestamp_ms(&nft), E_AUCTION_HAS_ENDED);

        let sender = tx_context::sender(ctx);
        let start_time = clock::timestamp_ms(clock);
        let end_time = start_time + duration_ms; // <-- ESTA LÍNEA DEBE ESTAR AQUÍ
        let auction = Auction {
            id: object::new(ctx),
            nft: option::some(nft),
            seller: sender,
            is_tkt_auction: false, // <-- AÑADIDO
            reserve_price: reserve_price_mist, // <-- AÑADIDO
            start_price: start_price_mist,
            highest_bid: 0,
            highest_bidder: option::none(),
            bid_vault: balance::zero(),
            tkt_bid_vault: balance::zero(), // Se inicializa aunque no se use
            end_timestamp_ms: end_time,
            is_settled: false,
        };
        event::emit(AuctionCreated {
            auction_id: object::id(&auction),
            nft_id: object::id(option::borrow(&auction.nft)),
            seller: sender,
            end_time: auction.end_timestamp_ms,
            is_tkt_auction: false // <-- AÑADE ESTA LÍNEA
            });
            transfer::share_object(auction);
            }
            /// Inicia una nueva subasta en TKT
            public entry fun create_tkt_auction(
                nft: ExperienceNFT,
                start_price_mist: u64,
                reserve_price_mist: u64,
                duration_ms: u64,
                clock: &Clock,
                ctx: &mut TxContext
                ) {
                     // --- AÑADIDO: Verificación de Expiración ---
        assert!(
            experience_nft::expiration_timestamp_ms(&nft) == 0 || clock::timestamp_ms(clock) < experience_nft::expiration_timestamp_ms(&nft),
            E_AUCTION_HAS_ENDED // O un error E_TICKET_EXPIRED
        );
                    let sender = tx_context::sender(ctx);
                    let start_time = clock::timestamp_ms(clock);
                    let end_time = start_time + duration_ms; // <-- AÑADE ESTA LÍNEA
                    let auction = Auction {
                        id: object::new(ctx),
                        nft: option::some(nft),
                        seller: sender,
                        is_tkt_auction: true, // Se marca como subasta en TKT
                        reserve_price: reserve_price_mist,
                        start_price: start_price_mist,
                        highest_bid: 0,
                        highest_bidder: option::none(),
                        bid_vault: balance::zero(),
                        tkt_bid_vault: balance::zero(),
                        end_timestamp_ms: end_time,
                        is_settled: false,
                        };
                        event::emit(AuctionCreated {
                            auction_id: object::id(&auction),
                            nft_id: object::id(option::borrow(&auction.nft)),
                            seller: sender,
                            end_time: auction.end_timestamp_ms,
                            is_tkt_auction: true // <-- AÑADE ESTA LÍNEA
                            });
                            transfer::share_object(auction);
                            }
                            /// Permite a un usuario realizar una puja en SUI.
                            public entry fun place_bid(auction: &mut Auction,payment: Coin<SUI>,clock: &Clock,ctx: &mut TxContext) {
        assert!(!auction.is_tkt_auction, E_WRONG_COIN_TYPE);
        let bidder = tx_context::sender(ctx);
        let bid_amount = coin::value(&payment);
        let threshold = if (option::is_none(&auction.highest_bidder)) { auction.start_price } else { auction.highest_bid };
        assert!(bid_amount > threshold, E_BID_TOO_LOW);
        assert!(clock::timestamp_ms(clock) < auction.end_timestamp_ms, E_AUCTION_HAS_ENDED);
        if (auction.end_timestamp_ms - clock::timestamp_ms(clock) < ANTI_SNIPE_EXTENSION_MS) {
            auction.end_timestamp_ms = clock::timestamp_ms(clock) + ANTI_SNIPE_EXTENSION_MS;
        };
        // --- LÓGICA DE REEMBOLSO CORREGIDA ---
        if (option::is_some(&auction.highest_bidder)) {
            // 1. Extrae la dirección del postor anterior. El campo `highest_bidder` queda como `None`.
            let previous_bidder = option::extract(&mut auction.highest_bidder);
            // 2. Saca el balance anterior de la bóveda para devolverlo.
            let amount_to_refund = balance::value(&auction.bid_vault);
            let refund_balance = balance::split(&mut auction.bid_vault, amount_to_refund);
            // 3. Transfiere la puja anterior de vuelta a su dueño.
            transfer::public_transfer(coin::from_balance(refund_balance, ctx), previous_bidder);
        };
        // En este punto, estamos seguros de que la bóveda está vacía y no hay un `highest_bidder`.
        // 4. Se añade la nueva puja a la bóveda.
        balance::join(&mut auction.bid_vault, coin::into_balance(payment));
        // 5. Se establece el nuevo postor.
        option::fill(&mut auction.highest_bidder, bidder);
        auction.highest_bid = bid_amount;
        event::emit(BidPlaced { auction_id: object::id(auction), bidder, amount: bid_amount });
    }
    /// Permite a un usuario realizar una puja en TKT.
    public entry fun place_bid_tkt(
        auction: &mut Auction,
        payment: Coin<TKT>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(auction.is_tkt_auction, E_WRONG_COIN_TYPE);
        let bidder = tx_context::sender(ctx);
        let bid_amount = coin::value(&payment);
        let threshold = if (option::is_none(&auction.highest_bidder)) { auction.start_price } else { auction.highest_bid };
        assert!(bid_amount > threshold, E_BID_TOO_LOW);
        assert!(clock::timestamp_ms(clock) < auction.end_timestamp_ms, E_AUCTION_HAS_ENDED);
        if (auction.end_timestamp_ms - clock::timestamp_ms(clock) < ANTI_SNIPE_EXTENSION_MS) {
            auction.end_timestamp_ms = clock::timestamp_ms(clock) + ANTI_SNIPE_EXTENSION_MS;
        };
        if (option::is_some(&auction.highest_bidder)) {
            let previous_bidder = option::extract(&mut auction.highest_bidder);
            let amount_to_refund = balance::value(&auction.tkt_bid_vault);
            let refund_balance = balance::split(&mut auction.tkt_bid_vault, amount_to_refund);
            transfer::public_transfer(coin::from_balance(refund_balance, ctx), previous_bidder);
        };
        balance::join(&mut auction.tkt_bid_vault, coin::into_balance(payment));
        option::fill(&mut auction.highest_bidder, bidder);
        auction.highest_bid = bid_amount;
        event::emit(BidPlaced { auction_id: object::id(auction), bidder, amount: bid_amount });
    }
   /// Liquida una subasta finalizada en SUI
    public entry fun settle_sui_auction(
        auction: Auction,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
         let auction_id = object::id(&auction);
        // --- CORRECCIÓN: Se desestructuran TODOS los campos ---
        let Auction { 
            id, nft, seller, highest_bid, highest_bidder, bid_vault, tkt_bid_vault, 
            reserve_price, is_tkt_auction, end_timestamp_ms, is_settled, start_price: _ 
        } = auction;
        assert!(!is_tkt_auction, E_WRONG_COIN_TYPE);
        assert!(clock::timestamp_ms(clock) >= end_timestamp_ms, E_AUCTION_NOT_OVER);
        assert!(!is_settled, E_AUCTION_ALREADY_SETTLED);
        let nft_to_transfer = option::destroy_some(nft);
        // Si la subasta falla (sin pujas o no se alcanza el precio de reserva)
        if (option::is_none(&highest_bidder) || highest_bid < reserve_price) {
            transfer::public_transfer(nft_to_transfer, seller);
            balance::destroy_zero(bid_vault);
            balance::destroy_zero(tkt_bid_vault);
            event::emit(AuctionSettled { auction_id, winner: option::none(), final_price: 0 });
            object::delete(id);
            return
        };
        // Si la subasta es exitosa
        let winner = option::destroy_some(highest_bidder);
        let mut payment_balance = bid_vault;
        let royalty_config = experience_nft::royalties(&nft_to_transfer);
        let royalty_amount = (highest_bid * (experience_nft::royalty_basis_points(royalty_config) as u64)) / 10000;
        if (royalty_amount > 0) {
            let royalty_payment = coin::from_balance(balance::split(&mut payment_balance, royalty_amount), ctx);
            transfer::public_transfer(royalty_payment, experience_nft::royalty_recipient(royalty_config));
        };
        transfer::public_transfer(coin::from_balance(payment_balance, ctx), seller);
        transfer::public_transfer(nft_to_transfer, winner);
        event::emit(AuctionSettled { auction_id, winner: option::some(winner), final_price: highest_bid });
        balance::destroy_zero(tkt_bid_vault); // Se destruye el balance de TKT que no se usó
        object::delete(id);
    }
    /// Liquida una subasta finalizada en TKT
    public entry fun settle_tkt_auction(
        auction: Auction,
        dao_treasury: &mut DAOTreasury,
        tkt_cap: &mut TreasuryCap<TKT>, // <-- SE ESPECIFICA EL TIPO DE TOKEN
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let auction_id = object::id(&auction); 
        // --- CORRECCIÓN: Se desestructuran TODOS los campos ---
        let Auction { 
            id, nft, seller, highest_bid, highest_bidder, bid_vault, tkt_bid_vault, 
            reserve_price, is_tkt_auction, end_timestamp_ms, is_settled, start_price: _
        } = auction;
        assert!(is_tkt_auction, E_WRONG_COIN_TYPE);
        assert!(clock::timestamp_ms(clock) >= end_timestamp_ms, E_AUCTION_NOT_OVER);
        assert!(!is_settled, E_AUCTION_ALREADY_SETTLED);
        let nft_to_transfer = option::destroy_some(nft);
        if (option::is_none(&highest_bidder) || highest_bid < reserve_price) {
            transfer::public_transfer(nft_to_transfer, seller);
            balance::destroy_zero(bid_vault);
            balance::destroy_zero(tkt_bid_vault);
            event::emit(AuctionSettled { auction_id, winner: option::none(), final_price: 0 });
            object::delete(id);
            return
        };
        let winner = option::destroy_some(highest_bidder);
        let mut payment_balance = tkt_bid_vault;
        let royalty_config = experience_nft::royalties(&nft_to_transfer);
        let royalty_amount = (highest_bid * (experience_nft::royalty_basis_points(royalty_config) as u64)) / 10000;
        if (royalty_amount > 0) {
            let royalty_payment = coin::from_balance(balance::split(&mut payment_balance, royalty_amount), ctx);
            transfer::public_transfer(royalty_payment, experience_nft::royalty_recipient(royalty_config));
        };
        let fee_amount = (highest_bid * PLATFORM_FEE_BASIS_POINTS) / 10000;
        if (fee_amount > 0) {
            let mut fee_balance = balance::split(&mut payment_balance, fee_amount);
            let fee_value = balance::value(&fee_balance);
            let rewards_part = balance::split(&mut fee_balance, fee_value * 40 / 100);
            let dao_part = balance::split(&mut fee_balance, fee_value * 30 / 100);
            deposit_to_treasury(dao_treasury, coin::from_balance(rewards_part, ctx));
            deposit_to_treasury(dao_treasury, coin::from_balance(dao_part, ctx));
            coin::burn(tkt_cap, coin::from_balance(fee_balance, ctx));
        };
        transfer::public_transfer(coin::from_balance(payment_balance, ctx), seller);
        transfer::public_transfer(nft_to_transfer, winner);
        event::emit(AuctionSettled { auction_id, winner: option::some(winner), final_price: highest_bid });
        balance::destroy_zero(bid_vault); // Se destruye el balance de SUI que no se usó
        object::delete(id);
    }
} 
