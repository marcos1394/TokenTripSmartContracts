module tokentrip_rental_market::rental_market {
    // --- DEPENDENCIAS ---
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use std::string::{String as StdString};
    use sui::url::{Url as SuiUrl};
    
    // --- IMPORTACIONES DE OTROS MÓDULOS ---
    use tokentrip_experiences::experience_nft::Fraction;
    use tokentrip_token::tkt::TKT;

    // --- CÓDIGOS DE ERROR ---
    const E_ALREADY_RENTED: u64 = 1;
    const E_RENTAL_PERIOD_NOT_OVER: u64 = 2;
    const E_UNAUTHORIZED: u64 = 3;
    const E_INSUFFICIENT_FUNDS: u64 = 4;
    const E_WRONG_CURRENCY: u64 = 5;

    // --- STRUCTS ---
    
    /// Un listado público para alquilar una fracción de un NFT.
    /// Guarda la Fracción en escrow hasta que el alquiler termina.
    public struct RentalListing has key, store {
        id: UID,
        /// La Fracción que está en alquiler, guardada de forma segura.
        fraction: Fraction,
        /// El dueño original de la Fracción.
        owner: address,
        /// El precio del alquiler.
        price: u64,
        /// `true` si el precio es en TKT.
        is_tkt_listing: bool,
        /// Timestamp de inicio del periodo de alquiler.
        start_timestamp_ms: u64,
        /// Timestamp de fin del periodo de alquiler.
        end_timestamp_ms: u64,
        /// `true` si la fracción ya ha sido alquilada.
        is_rented: bool,
    }

    /// Un "ticket" intransferible que prueba el derecho de uso de una Fracción
    /// durante un periodo de tiempo.
    public struct RentalReceipt has key {
        id: UID,
        /// La dirección del inquilino.
        renter: address,
        /// El ID de la Fracción original que fue alquilada.
        original_fraction_id: ID,
        /// El nombre del NFT padre, para mostrar en la UI.
        parent_nft_name: StdString,
        /// La URL de la imagen del NFT padre.
        parent_nft_image_url: SuiUrl,
        /// Inicio del periodo de validez del ticket.
        start_timestamp_ms: u64,
        /// Fin del periodo de validez del ticket.
        end_timestamp_ms: u64,
    }

    // --- EVENTOS ---
    public struct FractionListedForRent has copy, drop {
        listing_id: ID,
        fraction_id: ID,
        owner: address,
        price: u64,
        is_tkt_listing: bool,
    }

    public struct FractionRented has copy, drop {
        listing_id: ID,
        fraction_id: ID,
        owner: address,
        renter: address,
        receipt_id: ID,
    }

    public struct FractionReclaimed has copy, drop {
        listing_id: ID,
        fraction_id: ID,
        owner: address,
    }

    // --- FUNCIONES ---

    /// [Dueño] Lista una Fracción para alquilar a cambio de SUI.
    public entry fun list_fraction_for_rent(
        fraction: Fraction,
        price_in_mist: u64,
        start_timestamp_ms: u64,
        end_timestamp_ms: u64,
        ctx: &mut TxContext
    ) {
        let owner = tx_context::sender(ctx);
        let listing = RentalListing {
            id: object::new(ctx),
            fraction,
            owner,
            price: price_in_mist,
            is_tkt_listing: false,
            start_timestamp_ms,
            end_timestamp_ms,
            is_rented: false,
        };
        
        event::emit(FractionListedForRent {
            listing_id: object::id(&listing),
            fraction_id: object::id(&listing.fraction),
            owner,
            price: price_in_mist,
            is_tkt_listing: false,
        });

        transfer::share_object(listing);
    }

    /// [Dueño] Lista una Fracción para alquilar a cambio de TKT.
    public entry fun list_fraction_for_rent_tkt(
        fraction: Fraction,
        price_in_tkt_mist: u64,
        start_timestamp_ms: u64,
        end_timestamp_ms: u64,
        ctx: &mut TxContext
    ) {
        let owner = tx_context::sender(ctx);
        let listing = RentalListing {
            id: object::new(ctx),
            fraction,
            owner,
            price: price_in_tkt_mist,
            is_tkt_listing: true,
            start_timestamp_ms,
            end_timestamp_ms,
            is_rented: false,
        };

        event::emit(FractionListedForRent { /* ... */ });
        transfer::share_object(listing);
    }
    
    /// [Inquilino] Alquila una Fracción pagando con SUI.
    public entry fun rent_fraction(
        listing: &mut RentalListing,
        payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(!listing.is_tkt_listing, E_WRONG_CURRENCY);
        assert!(!listing.is_rented, E_ALREADY_RENTED);
        assert!(coin::value(&payment) >= listing.price, E_INSUFFICIENT_FUNDS);

        let renter = tx_context::sender(ctx);
        listing.is_rented = true;

        let receipt = RentalReceipt {
            id: object::new(ctx),
            renter,
            original_fraction_id: object::id(&listing.fraction),
            parent_nft_name: listing.fraction.parent_name,
            parent_nft_image_url: listing.fraction.parent_image_url,
            start_timestamp_ms: listing.start_timestamp_ms,
            end_timestamp_ms: listing.end_timestamp_ms,
        };
        let receipt_id = object::id(&receipt);
        transfer::public_transfer(receipt, renter);
        
        // El pago se transfiere directamente al dueño de la fracción
        transfer::public_transfer(payment, listing.owner);

        event::emit(FractionRented {
            listing_id: object::id(listing),
            fraction_id: object::id(&listing.fraction),
            owner: listing.owner,
            renter,
            receipt_id,
        });
    }

    // (Aquí iría la función `rent_fraction_tkt`, que sería casi idéntica pero aceptando Coin<TKT>)

    /// [Dueño] Reclama su Fracción una vez que el periodo de alquiler ha terminado.
    public entry fun reclaim_fraction(
        listing: RentalListing,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(clock::timestamp_ms(clock) >= listing.end_timestamp_ms, E_RENTAL_PERIOD_NOT_OVER);
        let owner = tx_context::sender(ctx);
        assert!(owner == listing.owner, E_UNAUTHORIZED);
        
        let RentalListing { id, fraction, owner, .. } = listing;

        event::emit(FractionReclaimed {
            listing_id: object::id_from_uid(&id),
            fraction_id: object::id(&fraction),
            owner,
        });
        
        transfer::public_transfer(fraction, owner);
        object::delete(id);
    }
}
