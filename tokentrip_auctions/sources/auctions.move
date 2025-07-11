module tokentrip_auctions::auctions {
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use std::option::{Self, Option};

    // Importamos el tipo de NFT de nuestro otro paquete
    use tokentrip_experiences::experience_nft::ExperienceNFT;

    // --- ERRORES ---
    const E_AUCTION_NOT_OVER: u64 = 1;
    const E_AUCTION_ALREADY_SETTLED: u64 = 2;
    const E_BID_TOO_LOW: u64 = 3;
    const E_AUCTION_HAS_ENDED: u64 = 4;
    const E_CANNOT_BID_ON_OWN_AUCTION: u64 = 5;

    // --- STRUCTS ---
    public struct AUCTIONS has drop {} // Testigo de un solo uso

    /// Objeto compartido que representa una subasta activa
    public struct Auction has key, store {
        id: UID,
        nft: ExperienceNFT, // El NFT que se está subastando
        seller: address,
        start_price: u64,
        highest_bid: u64,
        highest_bidder: Option<address>,
        start_timestamp_ms: u64,
        end_timestamp_ms: u64,
        is_settled: bool,
    }

    // --- EVENTOS ---
    public struct AuctionCreated has copy, drop { auction_id: ID, nft_id: ID, seller: address, end_time: u64 }
    public struct BidPlaced has copy, drop { auction_id: ID, bidder: address, amount: u64 }
    public struct AuctionSettled has copy, drop { auction_id: ID, winner: address, final_price: u64 }

    // --- FUNCIONES ---
    fun init(_: AUCTIONS, _: &mut TxContext) {
        // La inicialización no necesita hacer nada en este módulo.
    }

    /// Inicia una nueva subasta para un ExperienceNFT
    public entry fun create_auction(
        nft: ExperienceNFT,
        start_price_mist: u64,
        duration_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let start_time = clock::timestamp_ms(clock);
        let end_time = start_time + duration_ms;

        let auction = Auction {
            id: object::new(ctx),
            nft: nft, // El NFT ahora vive dentro del objeto Auction
            seller: sender,
            start_price: start_price_mist,
            highest_bid: start_price_mist,
            highest_bidder: option::none(),
            start_timestamp_ms: start_time,
            end_timestamp_ms: end_time,
            is_settled: false,
        };

        event::emit(AuctionCreated { 
            auction_id: object::id(&auction), 
            nft_id: object::id(&auction.nft),
            seller: sender,
            end_time
        });
        transfer::share_object(auction);
    }

    /// Permite a un usuario realizar una puja en una subasta activa
    public entry fun place_bid(
        auction: &mut Auction,
        payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let bidder = tx_context::sender(ctx);
        assert!(clock::timestamp_ms(clock) < auction.end_timestamp_ms, E_AUCTION_HAS_ENDED);
        assert!(bidder != auction.seller, E_CANNOT_BID_ON_OWN_AUCTION);

        let bid_amount = coin::value(&payment);
        assert!(bid_amount > auction.highest_bid, E_BID_TOO_LOW);
        
        // Devolver la puja al postor anterior, si existe
        if (option::is_some(&auction.highest_bidder)) {
            let previous_bidder = *option::borrow(&auction.highest_bidder);
            let previous_bid_coin = coin::from_balance(balance::split(&mut coin::balance_mut(&mut payment), auction.highest_bid), ctx);
            transfer::public_transfer(previous_bid_coin, previous_bidder);
        };
        
        // El resto se une al objeto de la puja actual
        balance::join(coin::balance_mut(&mut payment), coin::into_balance(payment));

        // Se actualizan los datos de la subasta
        auction.highest_bid = bid_amount;
        auction.highest_bidder = option::some(bidder);

        event::emit(BidPlaced {
            auction_id: object::id(auction),
            bidder,
            amount: bid_amount
        });
    }

    /// Liquida una subasta finalizada
    public entry fun settle_auction(
        auction: Auction,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(clock::timestamp_ms(clock) >= auction.end_timestamp_ms, E_AUCTION_NOT_OVER);
        assert!(!auction.is_settled, E_AUCTION_ALREADY_SETTLED);

        let Auction { 
            id, nft, seller, highest_bid, highest_bidder, 
            start_price: _, start_timestamp_ms: _, end_timestamp_ms: _, is_settled: _
        } = auction;

        if (option::is_some(&highest_bidder)) {
            let winner = option::destroy_some(highest_bidder);
            
            // Transferir el NFT al ganador
            transfer::public_transfer(nft, winner);
            
            // Transferir los fondos (la puja más alta) al vendedor
            let payment = coin::from_balance(balance::split(&mut coin::balance_mut_for_testing(ctx), highest_bid), ctx);
            transfer::public_transfer(payment, seller);
            
            event::emit(AuctionSettled { auction_id: object::id_from_uid(&id), winner, final_price: highest_bid });
        } else {
            // Si nadie pujó, el NFT vuelve al vendedor
            transfer::public_transfer(nft, seller);
        };

        // Se destruye el objeto Auction
        object::delete(id);
    }
}
