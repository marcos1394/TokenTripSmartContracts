module tokentrip_experiences::experience_nft {

    // --- DEPENDENCIAS BASE ---

    use sui::object::{Self, ID, UID};

    use sui::tx_context::{Self, TxContext};

    use sui::transfer;

    use sui::event;

    use std::string::{String as StdString, utf8};

    use sui::url::{Url as SuiUrl, new_unsafe_from_bytes, inner_url};

    use std::ascii::{String as AsciiString, into_bytes as ascii_into_bytes};

    use std::vector;



    // --- DEPENDENCIAS PARA PAGOS ---

    use sui::coin::{Self, Coin, destroy_zero};

    use sui::sui::SUI;

    use sui::balance::{Self, Balance};

    use tokentrip_token::tkt::TKT;

    use sui::table::{Self, Table};







    // --- CÓDIGOS DE ERROR ---

    const E_INSUFFICIENT_FUNDS: u64 = 1;

    const E_SOLD_OUT: u64 = 2;

    const E_INVALID_SHARES: u64 = 3;

    const E_UNAUTHORIZED: u64 = 4;

    const COMMISSION_BASIS_POINTS: u64 = 500; // 5.00%

    const E_ALREADY_REVIEWED: u64 = 5; // NUEVO

    const VIP_COMMISSION_BASIS_POINTS: u64 = 250; // NUEVO: 2.50% para VIPs







    // --- STRUCTS ---

    public struct AdminCap has key, store { id: UID }



     // --- NUEVO: Struct para la Lista VIP ---

    public struct VipRegistry has key, store {

        id: UID,

        // Un mapa que asocia la dirección de un proveedor con un booleano `true` si es VIP.

        vips: Table<address, bool>

    }





       public struct ProviderProfile has key, store {

        id: UID,

        owner: address,

        name: StdString,

        bio: StdString,

        image_url: SuiUrl,

        active_listings: vector<ID>,

        // NUEVO: Campos para el sistema de calificación

        total_reviews: u64,

        total_rating_points: u64,

    }



     // --- NUEVO: Struct para el Recibo de Compra "Inteligente" ---

    public struct PurchaseReceipt has key, store {

        id: UID,

        buyer: address,

        listing_id: ID,

        provider_id: ID,

        // Se añade una copia de los datos clave para la UI

        nft_name: StdString,

        nft_image_url: SuiUrl,

    }



     public struct Review has key, store {

        id: UID,

        reviewer: address,

        provider_id: ID,

        listing_id: ID,

        rating: u8, // Calificación de 1 a 5

        comment: StdString

    }



    public struct StakeReceipt has key, store {

        id: UID,

        owner: address,

        amount_staked: u64

    }



    public struct Attribute has copy, drop, store {

        key: StdString,

        value: StdString

    }



    public struct ExperienceNFT has key, store {

        id: UID, name: StdString, description: StdString, image_url: SuiUrl,

        event_name: StdString, event_city: StdString, validity_details: StdString,

        experience_type: StdString, issuer_name: StdString, tier: StdString,

        serial_number: u64, attributes: vector<Attribute>,

        collection_name: StdString, royalties: RoyaltyConfig,

        provider_id: ID,

        provider_address: address





    }



    public struct RoyaltyConfig has copy, drop, store {

        recipient: address,

        basis_points: u16

    }



    public struct TreasuryCap has key, store {

        id: UID,

        balance: Balance<SUI>

    }



    public struct Listing has key, store {

        id: UID,

        nft: ExperienceNFT,

        price: u64,

        is_available: bool,

        seller: address,

        provider_id: ID,

        is_tkt_listing: bool

    }



      public struct StakingPool has key, store {

        id: UID,

        total_staked: Balance<TKT>, // <-- AHORA ES DE TIPO TKT

        rewards: Balance<SUI>       // <-- Las recompensas siguen siendo en SUI

    }



    public struct Fraction has key, store {

        id: UID,

        parent_id: ID,

        share: u64,

        parent_name: StdString,

        parent_image_url: SuiUrl,

    }



    // --- EVENTOS ---

    public struct ProviderRegistered has copy, drop { provider_id: ID, owner: address, name: StdString }

    public struct MintedExperienceNFT has copy, drop { object_id: ID, name: StdString, recipient: address, minter: address }

    public struct NftListed has copy, drop { listing_id: ID, nft_id: ID, price: u64 }

    public struct NftPurchased has copy, drop { listing_id: ID, nft_id: ID, buyer: address, price: u64 }

    public struct NftFractioned has copy, drop { parent_id: ID, shares: vector<u64> }

     public struct ReviewAdded has copy, drop {

        review_id: ID,

        provider_id: ID,

        listing_id: ID,

        reviewer: address,

        rating: u8

    }

     public struct NftUpdated has copy, drop { 

        nft_id: ID,

        provider_id: ID

    }

    // --- FUNCIÓN DE INICIALIZACIÓN ---

    // CORRECCIÓN: Se usa `public(package)` para que sea visible solo para las pruebas.

    fun init(ctx: &mut TxContext) {

        let sender = tx_context::sender(ctx);

        transfer::transfer(AdminCap { id: object::new(ctx) }, sender);

        transfer::share_object(TreasuryCap { id: object::new(ctx), balance: balance::zero()});

        transfer::share_object(StakingPool { id: object::new(ctx), total_staked: balance::zero(), rewards: balance::zero() });

        transfer::share_object(VipRegistry {id: object::new(ctx), vips: table::new(ctx)});



    }



    public entry fun list_for_sale_with_tkt(

    provider_profile: &mut ProviderProfile, 

    nft: ExperienceNFT, 

    price_in_tkt_mist: u64, 

    ctx: &mut TxContext

) {

    assert!(tx_context::sender(ctx) == provider_profile.owner, E_UNAUTHORIZED);

    let listing = Listing {

        id: object::new(ctx), 

        nft, 

        price: price_in_tkt_mist, 

        is_available: true,

        seller: provider_profile.owner, 

        provider_id: object::id(provider_profile),

        is_tkt_listing: true // Marcamos que es un listado en TKT

    };

    let listing_id = object::id(&listing);

    vector::push_back(&mut provider_profile.active_listings, listing_id);

    event::emit(NftListed { listing_id, nft_id: object::id(&listing.nft), price: price_in_tkt_mist });

    transfer::share_object(listing);

}



    public entry fun purchase_with_tkt(

    listing: Listing,

    // NOTA: Esta función necesitará una Tesorería para TKT, por ahora la omitimos

    // y enviamos la comisión al mismo vendedor para simplificar.

    // En un futuro, crearíamos un TreasuryCap<TKT>.

    mut payment: Coin<TKT>, 

    ctx: &mut TxContext

) {

    let buyer = tx_context::sender(ctx);

    assert!(listing.is_available, E_SOLD_OUT);

    assert!(listing.is_tkt_listing, E_UNAUTHORIZED); // Solo se puede usar con listings de TKT



    let total_payment = listing.price;

    assert!(coin::value(&payment) >= total_payment, E_INSUFFICIENT_FUNDS);



    // La lógica de comisión y pago ahora opera con TKT

    let commission = total_payment * COMMISSION_BASIS_POINTS / 10000;

    

    let commission_coin = coin::split(&mut payment, commission, ctx);

    // Por ahora, la tesorería (vendedor) recibe la comisión en TKT.

    transfer::public_transfer(commission_coin, listing.seller);



    // El resto del pago en TKT va al vendedor.

    transfer::public_transfer(payment, listing.seller);

    

    // El resto del flujo es idéntico al de `purchase`

    let listing_id = object::id(&listing);

    let provider_id = listing.provider_id;

    let nft_name_copy = listing.nft.name;

    let nft_image_url_copy = listing.nft.image_url;

    

    let Listing { id, nft, price: _, is_available: _, seller: _, provider_id: _, is_tkt_listing: _ } = listing;

    let nft_id = object::id(&nft);



    transfer::public_transfer(nft, buyer);



    // Se crea el recibo de compra

    let receipt = PurchaseReceipt {

        id: object::new(ctx),

        buyer: buyer,

        listing_id: listing_id,

        provider_id: provider_id,

        nft_name: nft_name_copy,

        nft_image_url: nft_image_url_copy

    };

    transfer::public_transfer(receipt, buyer);

    

    event::emit(NftPurchased { listing_id, nft_id, buyer, price: total_payment });

    object::delete(id);

}





      // --- NUEVO: Funciones de Admin para gestionar la Lista VIP ---

    public entry fun add_vip(

        _admin_cap: &AdminCap,

        registry: &mut VipRegistry,

        provider_address: address

    ) {

        table::add(&mut registry.vips, provider_address, true);

    }



     public entry fun remove_vip(

        _admin_cap: &AdminCap,

        registry: &mut VipRegistry,

        provider_address: address

    ) {

        table::remove(&mut registry.vips, provider_address);

    }



  // --- FUNCIÓN DE ACUÑACIÓN ---

public fun mint_experience(

    _admin_cap: &AdminCap,

    provider_profile: &ProviderProfile, // Se necesita el perfil para asignar la autoría

    name_bytes: vector<u8>, 

    description_bytes: vector<u8>,

    image_url_bytes: vector<u8>, 

    event_name_bytes: vector<u8>, 

    event_city_bytes: vector<u8>,

    validity_details_bytes: vector<u8>, 

    experience_type_bytes: vector<u8>,

    tier_bytes: vector<u8>, 

    serial_number: u64, 

    collection_name_bytes: vector<u8>,

    royalty_recipient: address, 

    royalty_basis_points: u16,

    attributes: vector<Attribute>, 

    ctx: &mut TxContext

) : ExperienceNFT {

    let nft = ExperienceNFT {

        id: object::new(ctx),

        name: utf8(name_bytes),

        description: utf8(description_bytes),

        image_url: new_unsafe_from_bytes(image_url_bytes),

        event_name: utf8(event_name_bytes),

        event_city: utf8(event_city_bytes),

        validity_details: utf8(validity_details_bytes),

        experience_type: utf8(experience_type_bytes),

        issuer_name: utf8(b"TokenTrip"),

        tier: utf8(tier_bytes),

        serial_number: serial_number,

        attributes: attributes,

        collection_name: utf8(collection_name_bytes),

        royalties: RoyaltyConfig {

            recipient: royalty_recipient,

            basis_points: royalty_basis_points

        },

        // Se guarda el ID del perfil del proveedor en el NFT

        provider_id: object::id(provider_profile),

        // Se guarda también la dirección del proveedor para facilitar las comprobaciones

        provider_address: provider_profile.owner

    };



    event::emit(MintedExperienceNFT {

        object_id: object::id(&nft),

        name: nft.name,

        recipient: tx_context::sender(ctx), // El admin sigue siendo el receptor inicial del mint

        minter: tx_context::sender(ctx)

    });

    

    nft

}

    

   public entry fun register_provider(

        name_bytes: vector<u8>, bio_bytes: vector<u8>, image_url_bytes: vector<u8>, ctx: &mut TxContext

    ) {

        let sender = tx_context::sender(ctx);

        let profile = ProviderProfile {

            id: object::new(ctx),

            owner: sender, name: utf8(name_bytes), bio: utf8(bio_bytes),

            image_url: new_unsafe_from_bytes(image_url_bytes), active_listings: vector::empty(),

            // Se inicializan los contadores de reputación

            total_reviews: 0,

            total_rating_points: 0,

        };

        event::emit(ProviderRegistered { provider_id: object::id(&profile), owner: sender, name: profile.name });

    transfer::share_object(profile);

    }







   // --- FUNCIONES DEL MERCADO ---

public entry fun list_for_sale(

    provider_profile: &mut ProviderProfile, 

    nft: ExperienceNFT, 

    price_in_mist: u64, 

    ctx: &mut TxContext

) {

    // Verificación de seguridad: solo el dueño del perfil puede usarlo para listar.

    assert!(tx_context::sender(ctx) == provider_profile.owner, E_UNAUTHORIZED);

    // Verificación adicional: solo el creador original puede hacer una venta primaria.

    assert!(provider_profile.owner == nft.provider_address, E_UNAUTHORIZED);



    let listing = Listing {

        id: object::new(ctx), 

        nft, 

        price: price_in_mist, 

        is_available: true,

        seller: provider_profile.owner, 

        provider_id: object::id(provider_profile),

        is_tkt_listing: false // Se establece como venta en SUI por defecto

    };



    let listing_id = object::id(&listing);

    vector::push_back(&mut provider_profile.active_listings, listing_id);



    event::emit(NftListed {

        listing_id,

        nft_id: object::id(&listing.nft),

        price: price_in_mist

    });



    transfer::share_object(listing);

}



    // --- NUEVO: Función para que CUALQUIER usuario pueda revender ---

    public entry fun list_for_resale(

        nft: ExperienceNFT, 

        price_in_mist: u64, 

        ctx: &mut TxContext

    ) {

        let sender = tx_context::sender(ctx);

        // No se puede listar para la reventa un artículo que no se ha vendido antes.

        // El creador original debe usar `list_for_sale`.

        assert!(sender != nft.provider_address, E_UNAUTHORIZED);



        // Se crea un listing estándar, pero el `seller` será el revendedor.

        let listing = Listing {

            id: object::new(ctx), 

            nft, 

            price: price_in_mist, 

            is_available: true,

            seller: sender, 

            provider_id: nft.provider_id, // Se mantiene el ID del proveedor original

            is_tkt_listing: false // Asumimos reventa en SUI por ahora

        };

        transfer::share_object(listing);

    }



   public entry fun purchase(

    listing: Listing,

    treasury_cap: &mut TreasuryCap,

    vip_registry: &VipRegistry,

    _staking_pool: &mut StakingPool,

    mut payment: Coin<SUI>,

    ctx: &mut TxContext

) {

    // 1. Verificaciones iniciales

    let buyer = tx_context::sender(ctx);

    assert!(listing.is_available, E_SOLD_OUT);

    let total_payment = listing.price;

    assert!(coin::value(&payment) >= total_payment, E_INSUFFICIENT_FUNDS);



    let seller = listing.seller;

    let original_provider_addr = listing.nft.provider_address;



    // 2. Lógica de pago condicional

    if (seller == original_provider_addr) {

        // --- CASO 1: VENTA PRIMARIA (DEL CREADOR ORIGINAL) ---

        

        // Se aplica la lógica de comisiones VIP que ya teníamos

        let mut commission_rate = COMMISSION_BASIS_POINTS;

        if (table::contains(&vip_registry.vips, seller)) {

            commission_rate = VIP_COMMISSION_BASIS_POINTS;

        };

        let commission = total_payment * commission_rate / 10000;

        

        // La comisión va a la tesorería

        let commission_coin = coin::split(&mut payment, commission, ctx);

        balance::join(&mut treasury_cap.balance, coin::into_balance(commission_coin));

        

        // El resto va para el proveedor/vendedor

        transfer::public_transfer(payment, seller);



    } else {

        // --- CASO 2: VENTA SECUNDARIA (DE UN USUARIO A OTRO) ---



        // 2a. Comisión para la plataforma (siempre la misma en reventa)

        let commission = total_payment * COMMISSION_BASIS_POINTS / 10000;

        let commission_coin = coin::split(&mut payment, commission, ctx);

        balance::join(&mut treasury_cap.balance, coin::into_balance(commission_coin));

        

        // 2b. Regalía para el creador original del NFT

        let royalty_points = (listing.nft.royalties.basis_points as u64);

        if (royalty_points > 0) {

            let royalty_amount = total_payment * royalty_points / 10000;

            let royalty_coin = coin::split(&mut payment, royalty_amount, ctx);

            transfer::public_transfer(royalty_coin, original_provider_addr);

        };



        // 2c. El resto del pago es para el revendedor

        transfer::public_transfer(payment, seller);

    };

    

    // 3. El resto del flujo es idéntico para ambos casos

    let listing_id = object::id(&listing);

    let provider_id = listing.provider_id;

    let nft_name_copy = listing.nft.name;

    let nft_image_url_copy = listing.nft.image_url;

    

    let Listing { id, nft, price: _, is_available: _, seller: _, provider_id: _, is_tkt_listing: _ } = listing;

    let nft_id = object::id(&nft);



    // Se transfiere el NFT al nuevo comprador

    transfer::public_transfer(nft, buyer);



    // Se crea y transfiere el recibo de compra

    let receipt = PurchaseReceipt {

        id: object::new(ctx),

        buyer: buyer,

        listing_id: listing_id,

        provider_id: provider_id,

        nft_name: nft_name_copy,

        nft_image_url: nft_image_url_copy

    };

    transfer::public_transfer(receipt, buyer);

    

    event::emit(NftPurchased {

        listing_id,

        nft_id,

        buyer,

        price: total_payment

    });



    // Se destruye el objeto Listing

    object::delete(id);

}



public entry fun update_nft_description(

        profile: &ProviderProfile,

        nft: &mut ExperienceNFT,

        new_description: vector<u8>,

        ctx: &mut TxContext

    ) {

        // Verificación de seguridad: solo el proveedor original puede editar el NFT.

        assert!(object::id(profile) == nft.provider_id, E_UNAUTHORIZED);

        assert!(tx_context::sender(ctx) == profile.owner, E_UNAUTHORIZED);



        // Se actualiza la descripción.

        nft.description = utf8(new_description);



        event::emit(NftUpdated {

            nft_id: object::id(nft),

            provider_id: object::id(profile)

        });

    }



    // --- NUEVO: Función para Añadir una Reseña ---

    public entry fun add_review(

        provider_profile: &mut ProviderProfile,

        receipt: PurchaseReceipt,

        rating: u8,

        comment_bytes: vector<u8>,

        ctx: &mut TxContext

    ) {

        let reviewer = tx_context::sender(ctx);

        // Solo el comprador que tiene el recibo puede dejar la reseña

        assert!(reviewer == receipt.buyer, E_UNAUTHORIZED);

        // La reseña debe ser para el proveedor correcto

        assert!(object::id(provider_profile) == receipt.provider_id, E_UNAUTHORIZED);

        // La calificación debe estar entre 1 y 5

        assert!(rating >= 1 && rating <= 5, E_INVALID_SHARES);



        // Actualizar la reputación del proveedor

        provider_profile.total_reviews = provider_profile.total_reviews + 1;

        provider_profile.total_rating_points = provider_profile.total_rating_points + (rating as u64);



        // Crear el objeto de la reseña

        let review = Review {

            id: object::new(ctx),

            reviewer,

            provider_id: receipt.provider_id,

            listing_id: receipt.listing_id,

            rating,

            comment: utf8(comment_bytes)

        };

        

        event::emit(ReviewAdded {

            review_id: object::id(&review),

            provider_id: review.provider_id,

            listing_id: review.listing_id,

            reviewer,

            rating

        });

        

        // Transferir la reseña al revisor (para que pueda verla, editarla o borrarla en el futuro)

        transfer::public_transfer(review, reviewer);



        // Quemar el recibo para que no se pueda volver a usar

        let PurchaseReceipt { id, buyer: _, listing_id: _, provider_id: _, nft_name:_, nft_image_url:_} = receipt;

        object::delete(id);

    }



    // --- STAKING FUNCTIONS ---



// CORRECCIÓN: La función ahora espera una moneda de tipo TKT.

public entry fun stake(

    pool: &mut StakingPool,

    coin: Coin<TKT>,

    ctx: &mut TxContext

) {

    let sender = tx_context::sender(ctx);

    let staked_amount = coin::value(&coin);



    // Se une el balance del Coin<TKT> al campo total_staked del pool, que es de tipo Balance<TKT>.

    balance::join(&mut pool.total_staked, coin::into_balance(coin));

    

    // Se crea el recibo para el usuario.

    let receipt = StakeReceipt {

        id: object::new(ctx),

        owner: sender,

        amount_staked: staked_amount

    };



    // Se transfiere el recibo al usuario que hizo el stake.

    transfer::public_transfer(receipt, sender);

}



    public entry fun claim_rewards(pool: &mut StakingPool, receipt: StakeReceipt, ctx: &mut TxContext) {

        let sender = tx_context::sender(ctx);

        assert!(sender == receipt.owner, E_UNAUTHORIZED);

        let staked_amount = receipt.amount_staked;

        let reward = staked_amount * 5 / 100;

        let reward_balance = balance::split(&mut pool.rewards, reward);

        let reward_coin = coin::from_balance(reward_balance, ctx);

        transfer::public_transfer(reward_coin, sender);

        let StakeReceipt { id, owner: _, amount_staked: _ } = receipt;

        object::delete(id);

    }



    // --- FRACCIONAMIENTO DE NFTs ---

    public entry fun fractionize(

        nft: ExperienceNFT, shares: vector<u64>, recipients: vector<address>, ctx: &mut TxContext

    ) {

        let owner = tx_context::sender(ctx);

        let parent_id = object::id(&nft);

        let parent_name = nft.name;

        let parent_image_url = nft.image_url;

        let mut total_transferred_shares = 0u64;

        let mut i = 0;

        let shares_len = vector::length(&shares);

        while (i < shares_len) {

            total_transferred_shares = total_transferred_shares + *vector::borrow(&shares, i);

            i = i + 1;

        };

        assert!(total_transferred_shares <= 100, E_INVALID_SHARES);

        assert!(vector::length(&recipients) == shares_len, E_INVALID_SHARES);

        let owner_share = 100 - total_transferred_shares;

        if (owner_share > 0) {

            let owner_fraction = Fraction {

                id: object::new(ctx), parent_id, share: owner_share,

                parent_name: parent_name, parent_image_url: parent_image_url,

            };

            transfer::public_transfer(owner_fraction, owner);

        };

        let mut j = 0;

        while (j < shares_len) {

            let share = *vector::borrow(&shares, j);

            let recipient = *vector::borrow(&recipients, j);

            if (share > 0) {

                let fraction = Fraction {

                    id: object::new(ctx), parent_id, share,

                    parent_name: parent_name, parent_image_url: parent_image_url,

                };

                transfer::public_transfer(fraction, recipient);

            };

            j = j + 1;

        };

// CORRECCIÓN: Se añade el campo `provider_id` a la desestructuración.

        let ExperienceNFT { id, name:_, description:_, image_url:_, event_name:_, event_city:_, validity_details:_, experience_type:_, issuer_name:_, tier:_, serial_number:_, attributes:_, collection_name:_, royalties:_, provider_id: _ } = nft;

        object::delete(id);

        event::emit(NftFractioned { parent_id, shares });

    }



    // --- GETTERS Y HELPERS PÚBLICOS ---

    public fun new_attribute(key: vector<u8>, value: vector<u8>): Attribute {

        Attribute { key: utf8(key), value: utf8(value) }

    }

    public fun treasury_balance(cap: &TreasuryCap): u64 { balance::value(&cap.balance) }

    public fun name(nft: &ExperienceNFT): StdString { nft.name }

    public fun total_staked(pool: &StakingPool): u64 { balance::value(&pool.total_staked) }

    public fun amount_staked(receipt: &StakeReceipt): u64 { receipt.amount_staked }

    public fun share(fraction: &Fraction): u64 { fraction.share }

    public fun get_attributes(nft: &ExperienceNFT): &vector<Attribute> { &nft.attributes }

    public fun get_royalties(nft: &ExperienceNFT): &RoyaltyConfig { &nft.royalties }

    public fun basis_points(config: &RoyaltyConfig): u16 { config.basis_points }

       // --- NUEVO: Getters para los campos privados que necesitan las pruebas ---

    public fun provider_name(profile: &ProviderProfile): StdString { profile.name }

    public fun provider_owner(profile: &ProviderProfile): address { profile.owner }

    public fun provider_total_reviews(profile: &ProviderProfile): u64 { profile.total_reviews }

    public fun provider_total_rating_points(profile: &ProviderProfile): u64 { profile.total_rating_points }

    public fun receipt_buyer(receipt: &PurchaseReceipt): address { receipt.buyer }

    public fun review_rating(review: &Review): u8 { review.rating }

    public fun reviewer(review: &Review): address { review.reviewer }

      // --- NUEVO: Getters para el struct Listing ---

    public fun listing_price(listing: &Listing): u64 { listing.price }

    public fun listing_seller(listing: &Listing): address { listing.seller }

    public fun purchase_receipt_nft_name(receipt: &PurchaseReceipt): StdString { receipt.nft_name }

    public fun purchase_receipt_nft_image_url(receipt: &PurchaseReceipt): SuiUrl { receipt.nft_image_url }

    public fun nft_provider_id(nft: &ExperienceNFT): ID { nft.provider_id }

    public fun is_vip(registry: &VipRegistry, provider_address: address): bool {

        table::contains(&registry.vips, provider_address)

    }





    



    public entry fun burn_stake_receipt(receipt: StakeReceipt) {

        let StakeReceipt { id, owner: _, amount_staked: _ } = receipt;

        object::delete(id);

    }

    public entry fun burn_fraction(fraction: Fraction) {

        let Fraction { id, parent_id: _, share: _, parent_name: _, parent_image_url: _ } = fraction;

        object::delete(id);

    }

        public entry fun burn_review(review: Review) { let Review { id, reviewer: _, provider_id: _, listing_id: _, rating: _, comment: _ } = review; object::delete(id); }



    

  // --- NUEVO: Función para quemar el recibo de compra ---

    public entry fun burn_purchase_receipt(receipt: PurchaseReceipt) {

        let PurchaseReceipt { id, buyer: _, listing_id: _, provider_id: _, nft_name: _, nft_image_url: _ } = receipt;

        object::delete(id);

    }

}
