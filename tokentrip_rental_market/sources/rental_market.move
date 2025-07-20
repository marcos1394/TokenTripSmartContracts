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
        // --- INICIA CORRECCIÓN ---
        /// La Fracción que está en alquiler (si es un alquiler fraccional).
        fraction: Option<Fraction>,
        /// El NFT completo que está en alquiler (si es un alquiler completo).
        experience_nft: Option<ExperienceNFT>,
        // --- FIN CORRECCIÓN ---
        owner: address,
        price: u64,
        is_tkt_listing: bool,
        start_timestamp_ms: u64,
        end_timestamp_ms: u64,
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

    public struct NftListedForRent has copy, drop {
        listing_id: ID,
        nft_id: ID,
        owner: address,
        price: u64,
        is_tkt_listing: bool,
    }

    public struct NftReclaimed has copy, drop {
        listing_id: ID,
        nft_id: ID,
        owner: address,
    }

    public struct FractionDelisted has copy, drop {
        listing_id: ID,
        owner: address,
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

    /// [Dueño] Lista un ExperienceNFT completo para alquilar a cambio de SUI.
    public entry fun list_nft_for_rent(
        nft: ExperienceNFT,
        price_in_mist: u64,
        start_timestamp_ms: u64,
        end_timestamp_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verificación de que el NFT no ha expirado.
        assert!(
            nft.expiration_timestamp_ms == 0 || clock::timestamp_ms(clock) < nft.expiration_timestamp_ms,
            E_UNAUTHORIZED
        );

        let owner = tx_context::sender(ctx);
        let listing = RentalListing {
            id: object::new(ctx),
            fraction: option::none(),
            experience_nft: option::some(nft),
            owner,
            price: price_in_mist,
            is_tkt_listing: false,
            start_timestamp_ms,
            end_timestamp_ms,
            is_rented: false,
        };
        
        event::emit(NftListedForRent {
            listing_id: object::id(&listing),
            nft_id: object::id(option::borrow(&listing.experience_nft)),
            owner,
            price: price_in_mist,
            is_tkt_listing: false,
        });

        transfer::share_object(listing);
    }

    /// [Dueño] Lista un ExperienceNFT completo para alquilar a cambio de TKT.
    public entry fun list_nft_for_rent_tkt(
        nft: ExperienceNFT,
        price_in_tkt_mist: u64,
        start_timestamp_ms: u64,
        end_timestamp_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verificación de que el NFT no ha expirado.
        assert!(
            nft.expiration_timestamp_ms == 0 || clock::timestamp_ms(clock) < nft.expiration_timestamp_ms,
            E_UNAUTHORIZED
        );

        let owner = tx_context::sender(ctx);
        let listing = RentalListing {
            id: object::new(ctx),
            fraction: option::none(),
            experience_nft: option::some(nft),
            owner,
            price: price_in_tkt_mist,
            is_tkt_listing: true,
            start_timestamp_ms,
            end_timestamp_ms,
            is_rented: false,
        };
        
        event::emit(NftListedForRent {
            listing_id: object::id(&listing),
            nft_id: object::id(option::borrow(&listing.experience_nft)),
            owner,
            price: price_in_tkt_mist,
            is_tkt_listing: true,
        });

        transfer::share_object(listing);
    }

/// [Dueño] Cancela un listado de alquiler y reclama su Fracción, si no ha sido alquilada.
    public entry fun delist_fraction(
        listing: RentalListing,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == listing.owner, E_UNAUTHORIZED);
        assert!(!listing.is_rented, E_ALREADY_RENTED);
        
        let RentalListing { id, fraction, owner, .. } = listing;

        event::emit(FractionDelisted {
            listing_id: object::id_from_uid(&id),
            owner,
        });
        
        transfer::public_transfer(fraction, owner);
        object::delete(id);
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

        // --- CORRECCIÓN: Se completa el evento ---
        event::emit(FractionListedForRent {
            listing_id: object::id(&listing),
            fraction_id: object::id(&listing.fraction),
            owner,
            price: price_in_tkt_mist,
            is_tkt_listing: true,
        });

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

    /// [Inquilino] Alquila una Fracción pagando con TKT, aplicando la tokenomics de la plataforma.
    public entry fun rent_fraction_tkt(
        listing: &mut RentalListing,
        dao_treasury: &mut DAOTreasury, // <-- AÑADIDO
        tkt_treasury_cap: &mut TreasuryCap<TKT>, // <-- AÑADIDO
        payment: Coin<TKT>,
        ctx: &mut TxContext
    ) {
        assert!(listing.is_tkt_listing, E_WRONG_CURRENCY);
        assert!(!listing.is_rented, E_ALREADY_RENTED);
        let price = listing.price;
        assert!(coin::value(&payment) >= price, E_INSUFFICIENT_FUNDS);

        listing.is_rented = true;
        let renter = tx_context::sender(ctx);

        // --- INICIA LÓGICA DE ECONOMÍA ---
        let mut payment_balance = coin::into_balance(payment);
        
        // Se calcula y separa la comisión de la plataforma (ej. 5%)
        let fee_amount = (price * PLATFORM_FEE_BASIS_POINTS) / 10000;
        let mut fee_balance = balance::split(&mut payment_balance, fee_amount);

        // El resto del pago (95%) va al dueño de la fracción.
        transfer::public_transfer(coin::from_balance(payment_balance, ctx), listing.owner);

        // Se distribuye la comisión (el 5% restante)
        let fee_value = balance::value(&fee_balance);
        let rewards_part = balance::split(&mut fee_balance, fee_value * 40 / 100);
        let dao_part = balance::split(&mut fee_balance, fee_value * 30 / 100);
        
        // El 40% (rewards) y el 30% (DAO) se depositan en la tesorería de la DAO.
        deposit_to_treasury(dao_treasury, coin::from_balance(rewards_part, ctx));
        deposit_to_treasury(dao_treasury, coin::from_balance(dao_part, ctx));

        // El 30% restante se quema.
        coin::burn(tkt_treasury_cap, coin::from_balance(fee_balance, ctx));
        // --- FIN LÓGICA DE ECONOMÍA ---

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

        event::emit(FractionRented {
            listing_id: object::id(listing),
            fraction_id: object::id(&listing.fraction),
            owner: listing.owner,
            renter,
            receipt_id,
        });
    }

    /// [Dueño] Reclama su ExperienceNFT una vez que el periodo de alquiler ha terminado.
    public entry fun reclaim_nft(
        listing: RentalListing,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verificación 1: El periodo de alquiler debe haber terminado.
        assert!(clock::timestamp_ms(clock) >= listing.end_timestamp_ms, E_RENTAL_PERIOD_NOT_OVER);
        
        let owner = tx_context::sender(ctx);
        // Verificación 2: Solo el dueño original puede reclamar el NFT.
        assert!(owner == listing.owner, E_UNAUTHORIZED);
        
        // Se desestructura el listado para obtener sus partes.
        let RentalListing { id, fraction, experience_nft, owner, .. } = listing;

        // Se extrae el NFT completo del Option.
        let nft = option::destroy_some(experience_nft);
        // Se destruye el Option de la fracción, que estaba vacío.
        option::destroy_none(fraction);

        // Se emite un evento para notificar al frontend.
        event::emit(NftReclaimed {
            listing_id: object::id_from_uid(&id),
            nft_id: object::id(&nft),
            owner,
        });
        
        // Se transfiere el NFT de vuelta a su dueño original.
        transfer::public_transfer(nft, owner);
        // Se elimina el objeto de listado, que ya no es necesario.
        object::delete(id);
    }

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
