module tokentrip_experience::experience_nft {
    // --- DEPENDENCIAS ---
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    // PON ESTAS LÍNEAS AL PRINCIPIO DE TU ARCHIVO CON LAS OTRAS IMPORTACIONES
use std::string::{Self as string, String as StdString, utf8};
use sui::url::{Self as url, Url as SuiUrl, new_unsafe_from_bytes};
    use sui::coin::{Self, Coin, burn, TreasuryCap};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use std::vector;
    use std::bcs;
    use sui::display::{Self, Display};
    use sui::package::{Self, Publisher};

    // --- IMPORTACIONES DE NUESTROS OTROS MÓDULOS ---
    use tokentrip_token::tkt::TKT;
    use tokentrip_dao::dao::{DAOTreasury, deposit_to_treasury};
    use tokentrip_staking::staking::{StakingPool, deposit_rewards};

    // --- CÓDIGOS DE ERROR ---
    const E_INSUFFICIENT_FUNDS: u64 = 1;
    const E_LISTING_NOT_AVAILABLE: u64 = 2;
    const E_INVALID_SHARES: u64 = 3;
    const E_UNAUTHORIZED: u64 = 4;
    const E_ALREADY_REVIEWED: u64 = 5;
    const E_WRONG_CURRENCY: u64 = 6;
    // Al principio de tu archivo, con las otras constantes
    const E_INVALID_ARGUMENT: u64 = 7; // O el siguiente número disponible

    // --- CONSTANTES ---
    const PLATFORM_FEE_BASIS_POINTS: u64 = 500; // 5.00%
    const VIP_FEE_BASIS_POINTS: u64 = 250; // 2.50% para VIPs
    const ROYALTY_FEE_BASIS_POINTS: u16 = 250; // 2.50% - CORREGIDO a u16

    // --- STRUCTS ---

    // AÑADE ESTA LÍNEA AL PRINCIPIO DE TUS STRUCTS
    public struct EXPERIENCE_NFT has drop {}

    public struct AdminCap has key, store { 
        id: UID 
    }

    public struct VipRegistry has key, store {
        id: UID,
        vips: Table<address, bool>
    }

    public struct ProviderProfile has key, store {
        id: UID,
        owner: address,
        name: StdString,
        bio: StdString,
        image_url: SuiUrl,
        category: StdString,
        metadata: vector<Attribute>,
        is_verified: bool,      // <-- AÑADIDO: Para la verificación por la DAO
        tier: u8,               // <-- AÑADIDO: Para el sistema de reputación
        total_reviews: u64,
        total_rating_points: u64,
    }

    public struct EvolutionRule has store, drop, copy {
    trigger_type: u8, // 0 para Tiempo, 1 para Meta
    trigger_value: u64, // El timestamp o el valor de la meta
    new_image_url: SuiUrl,
    new_description: StdString,
    attributes_to_add: vector<Attribute>,
    is_triggered: bool, // Para asegurar que solo se active una vez
}

    public struct PurchaseReceipt has key, store {
        id: UID,
        buyer: address,
        listing_id: ID,
        provider_id: ID,
        nft_name: StdString,
        nft_image_url: SuiUrl,
    }

    public struct Review has key, store {
        id: UID,
        reviewer: address,
        provider_id: ID,
        listing_id: ID,
        rating: u8,
        comment: StdString
    }

    public struct Attribute has copy, drop, store {
        key: StdString,
        value: StdString
    }

    public struct RoyaltyConfig has copy, drop, store {
        recipient: address,
        basis_points: u16
    }

    public struct ExperienceNFT has key, store {
        id: UID, 
        name: StdString, 
        description: StdString, 
        image_url: SuiUrl,
        event_name: StdString, 
        event_city: StdString, 
        validity_details: StdString,
        experience_type: StdString, 
        issuer_name: StdString, 
        tier: StdString,
        serial_number: u64, 
        attributes: vector<Attribute>,
        collection_name: StdString, 
        royalties: RoyaltyConfig,
        provider_id: ID,
        provider_address: address,
        is_redeemable: bool,          // true si es un ticket/voucher, false si es un coleccionable
        expiration_timestamp_ms: u64, // Timestamp de expiración. 0 si nunca expira.
        evolution_rules: vector<EvolutionRule>, // <-- AÑADIDO

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

// --- AÑADE ESTE NUEVO STRUCT ---
    /// Un trofeo digital intransferible que prueba la asistencia a una experiencia.
    public struct ProofOfExperience has key, store {
        id: UID,
        original_nft_name: StdString,
        image_url: SuiUrl,
        provider_name: StdString, // Para saber quién organizó la experiencia
        attended_on_date: u64, // Timestamp de cuándo se redimió
    }

    public struct Fraction has key, store {
        id: UID,
        parent_id: ID,
        share: u64,
        parent_name: StdString,
        parent_image_url: SuiUrl,
    }

    // --- EVENTOS ---

    public struct ProviderRegistered has copy, drop {
        provider_id: ID, 
        owner: address, 
        name: StdString 
    }

// --- AÑADE ESTE NUEVO EVENTO ---
    public struct ExperienceRedeemed has copy, drop {
        poe_id: ID,
        original_nft_id: ID,
        owner: address
    }

    /// Devuelve el timestamp de expiración de un ExperienceNFT.
    public fun expiration_timestamp_ms(nft: &ExperienceNFT): u64 {
        nft.expiration_timestamp_ms
    }

    // --- GETTERS PÚBLICOS PARA EL DISPLAY ---
// Estas funciones le dan permiso al Indexador de Sui para leer los campos del NFT.
    

public fun description(nft: &ExperienceNFT): &StdString {
    &nft.description
}



public fun event_name(nft: &ExperienceNFT): &StdString {
    &nft.event_name
}

public fun event_city(nft: &ExperienceNFT): &StdString {
    &nft.event_city
}

public fun tier(nft: &ExperienceNFT): &StdString {
    &nft.tier
}

public fun collection_name(nft: &ExperienceNFT): &StdString {
    &nft.collection_name
}

    /// Devuelve `true` si una dirección está en el registro VIP.
    public fun is_vip(registry: &VipRegistry, addr: address): bool {
        table::contains(&registry.vips, addr)
    }

    /// Devuelve el nombre del NFT padre de una Fracción.
    public fun fraction_parent_name(fraction: &Fraction): StdString {
        fraction.parent_name
    }

    /// Devuelve la URL de la imagen del NFT padre de una Fracción.
    public fun fraction_parent_image_url(fraction: &Fraction): SuiUrl {
        fraction.parent_image_url
    }

    public struct NftMinted has copy, drop {
        object_id: ID, 
        provider_id: ID,
        name: StdString, 
        minter: address 
    }

    public struct NftListed has copy, drop {
        listing_id: ID, 
        nft_id: ID, 
        price: u64,
        is_tkt_listing: bool
    }

    public struct NftPurchased has copy, drop {
        listing_id: ID, 
        nft_id: ID, 
        buyer: address, 
        seller: address,
        price: u64 
    }

    public struct ProviderUpdated has copy, drop {
        provider_id: ID,
        is_verified: bool,
        new_tier: u8,
    }

    public struct NftEvolved has copy, drop {
        nft_id: ID,
        // Podemos añadir los nuevos valores para que sea más fácil para los indexers
        new_image_url: SuiUrl, 
        new_description: StdString,
    }

    public struct NftFractioned has copy, drop {
        parent_id: ID, 
        shares_created: u64 
    }

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

    // Función init final y completa
fun init(witness: EXPERIENCE_NFT, ctx: &mut TxContext) {
    let sender = tx_context::sender(ctx);

    transfer::transfer(AdminCap { id: object::new(ctx) }, sender);
    transfer::share_object(VipRegistry {id: object::new(ctx), vips: table::new(ctx)});

    let publisher = package::claim(witness, ctx);
    let mut display = display::new<ExperienceNFT>(&publisher, ctx);

    display::add_multiple(
        &mut display,
        vector[
            utf8(b"name"),
            utf8(b"description"),
            utf8(b"image_url"),
            utf8(b"collection"),
            utf8(b"event"),
            utf8(b"tier"),
            utf8(b"project_name"),
            utf8(b"project_url")
        ],
        vector[
            utf8(b"{name}"),
            utf8(b"{description}"),
            utf8(b"{image_url}"),
            utf8(b"{collection_name}"),
            utf8(b"{event_name}"),
            utf8(b"{tier}"),
            utf8(b"TokenTrip"),
            utf8(b"https://tokentrip.com")
        ]
    );
    
    transfer::public_transfer(publisher, sender);
    transfer::public_transfer(display, sender);
}

    
    // --- FUNCIONES DE GESTIÓN ---

    public entry fun add_vip(
        _admin_cap: &AdminCap,
        registry: &mut VipRegistry,
        provider_address: address
    ) {
        table::add(&mut registry.vips, provider_address, true);
    }

    // --- AÑADE ESTAS DOS FUNCIONES ---

    /// Devuelve el nombre de un ExperienceNFT.
    public fun name(nft: &ExperienceNFT): StdString {
        nft.name
    }

    /// Devuelve la URL de la imagen de un ExperienceNFT.
    public fun image_url(nft: &ExperienceNFT): SuiUrl {
        nft.image_url
    }

    public entry fun remove_vip(
        _admin_cap: &AdminCap,
        registry: &mut VipRegistry,
        provider_address: address
    ) {
        table::remove(&mut registry.vips, provider_address);
    }

    public entry fun register_provider(
        name_bytes: vector<u8>, 
        bio_bytes: vector<u8>, 
        image_url_bytes: vector<u8>,
        category_bytes: vector<u8>,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let profile = ProviderProfile {
            id: object::new(ctx),
            owner: sender, 
            name: utf8(name_bytes), 
            bio: utf8(bio_bytes),
            image_url: new_unsafe_from_bytes(image_url_bytes),
            category: utf8(category_bytes),
            metadata: vector::empty(),
            // --- Se inicializan los nuevos campos y se elimina active_listings ---
            is_verified: false, // Los nuevos proveedores no están verificados por defecto
            tier: 0,            // Todos empiezan en el nivel 0 (ej. Bronce)
            total_reviews: 0,
            total_rating_points: 0,
        };
        event::emit(ProviderRegistered { 
            provider_id: object::id(&profile), 
            owner: sender, 
            name: profile.name 
        });
        transfer::public_transfer(profile, sender);
    }

    public entry fun evolve_experience(
        nft: &mut ExperienceNFT, 
        provider_profile: &ProviderProfile, // Necesario para comprobar metas relacionadas con el proveedor
        clock: &Clock, 
        _ctx: &mut TxContext
    ) {
        // Se obtiene una referencia mutable al vector de reglas
        let rules = &mut nft.evolution_rules;
        let mut i = 0;
        let len = vector::length(rules);

        let current_time = clock::timestamp_ms(clock);

        // Se recorren todas las reglas para ver si alguna se puede activar
        while (i < len) {
            let rule = vector::borrow_mut(rules, i);

            // Solo se procesan las reglas que no han sido activadas antes
            if (!rule.is_triggered) {
                
                let mut should_trigger = false;

                // Caso 1: Disparador por TIEMPO
                if (rule.trigger_type == 0) { 
                    if (current_time >= rule.trigger_value) {
                        should_trigger = true;
                    }
                };

                // Caso 2: Disparador por META (ejemplo: N.º de reseñas del proveedor)
                if (rule.trigger_type == 1) {
                    if (provider_profile.total_reviews >= rule.trigger_value) {
                        should_trigger = true;
                    }
                };

                // Si alguna de las condiciones se cumplió, se aplica la evolución
                if (should_trigger) {
                    // Se actualizan los metadatos del NFT
                    nft.image_url = rule.new_image_url;
                    nft.description = rule.new_description;
                    
                    // Se añaden los nuevos atributos
                    vector::append(&mut nft.attributes, rule.attributes_to_add);
                    // Se marca la regla como activada para que no vuelva a usarse
                    rule.is_triggered = true;
                }
            };
            i = i + 1;
        };

        // Se emite un evento para notificar al mundo exterior del cambio
        event::emit(NftEvolved {
            nft_id: object::id(nft),
            new_image_url: nft.image_url,
            new_description: nft.description,
        });
    }

/// Permite a un admin marcar un perfil de proveedor como verificado.
    public entry fun verify_provider(
        _admin_cap: &AdminCap,
        profile: &mut ProviderProfile
    ) {
        profile.is_verified = true;

        event::emit(ProviderUpdated {
            provider_id: object::id(profile),
            is_verified: profile.is_verified,
            new_tier: profile.tier,
        });
    }

    /// Permite a un admin cambiar el nivel (tier) de un proveedor.
    public entry fun set_provider_tier(
        _admin_cap: &AdminCap,
        profile: &mut ProviderProfile,
        new_tier: u8
    ) {
        profile.tier = new_tier;

        event::emit(ProviderUpdated {
            provider_id: object::id(profile),
            is_verified: profile.is_verified,
            new_tier: profile.tier,
        });
    }

    public entry fun provider_mint_experience(
    provider_profile: &ProviderProfile,
    name: StdString,
    description: StdString,
    image_url: StdString,
    event_name: StdString,
    event_city: StdString,
    validity_details: StdString,
    experience_type: StdString,
    tier: StdString,
    serial_number: u64,
    collection_name: StdString,
    
    attribute_keys: vector<StdString>,
    attribute_values: vector<StdString>,
    
    is_redeemable: bool,
    expiration_timestamp_ms: u64,

    rule_trigger_types: vector<u8>,
    rule_trigger_values: vector<u64>,
    rule_new_image_urls: vector<StdString>,
    rule_new_descriptions: vector<StdString>,
    
    ctx: &mut TxContext
) {
    // 1. Verificación de autorización
    assert!(tx_context::sender(ctx) == provider_profile.owner, E_UNAUTHORIZED);

    // 2. Reconstruir el vector<Attribute>
    let mut attributes = vector::empty<Attribute>();
    let mut i = 0;
    let attr_len = vector::length(&attribute_keys);
    assert!(vector::length(&attribute_values) == attr_len, E_INVALID_ARGUMENT);
    
    while (i < attr_len) {
        vector::push_back(&mut attributes, Attribute { 
            key: *vector::borrow(&attribute_keys, i), 
            value: *vector::borrow(&attribute_values, i) 
        });
        i = i + 1;
    };

    // 3. Reconstruir el vector<EvolutionRule>
    let mut evolution_rules = vector::empty<EvolutionRule>();
    let mut j = 0;
    let rules_len = vector::length(&rule_trigger_types);

    while (j < rules_len) {
        vector::push_back(&mut evolution_rules, EvolutionRule {
            trigger_type: *vector::borrow(&rule_trigger_types, j),
            trigger_value: *vector::borrow(&rule_trigger_values, j),
            // --- CORRECCIÓN FINAL AQUÍ ---
            new_image_url: url::new_unsafe_from_bytes(*string::bytes(vector::borrow(&rule_new_image_urls, j))),
            new_description: *vector::borrow(&rule_new_descriptions, j),
            attributes_to_add: vector::empty(),
            is_triggered: false,
        });
        j = j + 1;
    };

    // 4. Crear el struct del NFT
    let nft = ExperienceNFT {
        id: object::new(ctx),
        name: name,
        description: description,
        // --- CORRECCIÓN FINAL AQUÍ ---
        image_url: url::new_unsafe_from_bytes(*string::bytes(&image_url)),
        event_name: event_name,
        event_city: event_city,
        validity_details: validity_details,
        experience_type: experience_type,
        issuer_name: utf8(b"TokenTrip"),
        tier: tier,
        serial_number: serial_number,
        attributes: attributes,
        collection_name: collection_name,
        royalties: RoyaltyConfig {
            recipient: provider_profile.owner,
            basis_points: ROYALTY_FEE_BASIS_POINTS
        },
        provider_id: object::id(provider_profile),
        provider_address: provider_profile.owner,
        is_redeemable: is_redeemable,
        expiration_timestamp_ms: expiration_timestamp_ms,
        evolution_rules: evolution_rules,
    };
    
    // 5. Emitir el evento
    event::emit(NftMinted {
        object_id: object::id(&nft),
        provider_id: object::id(provider_profile),
        name: nft.name,
        minter: provider_profile.owner
    });

    // 6. Transferir el NFT
    transfer::public_transfer(nft, provider_profile.owner);
}

/// Permite a un usuario redimir un ExperienceNFT para recibir un ProofOfExperience (SBT).
    /// Esta acción consume (quema) el ExperienceNFT original.
    public entry fun redeem_experience(
        nft: ExperienceNFT, 
        provider_profile: &ProviderProfile, // Se necesita para obtener el nombre del proveedor
        clock: &Clock, 
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let original_nft_id = object::id(&nft);

        // Verificación 1: El NFT debe ser redimible.
        assert!(nft.is_redeemable, E_UNAUTHORIZED); 
        // Verificación 2: El NFT no debe haber expirado.
        assert!(nft.expiration_timestamp_ms == 0 || clock::timestamp_ms(clock) < nft.expiration_timestamp_ms, E_UNAUTHORIZED);
        // Verificación 3: El perfil de proveedor debe ser el correcto para este NFT.
        assert!(object::id(provider_profile) == nft.provider_id, E_UNAUTHORIZED);

        // Se crea el nuevo "Recuerdo" (Proof of Experience NFT)
        let poe = ProofOfExperience {
            id: object::new(ctx),
            original_nft_name: nft.name,
            image_url: nft.image_url,
            provider_name: provider_profile.name,
            attended_on_date: clock::timestamp_ms(clock),
        };

        let poe_id = object::id(&poe);

        // Se transfiere el nuevo recuerdo intransferible al usuario
        transfer::public_transfer(poe, sender);
        
        event::emit(ExperienceRedeemed {
            poe_id,
            original_nft_id,
            owner: sender
        });
        
        // Se desestructura y quema el ExperienceNFT original
        let ExperienceNFT { id, .. } = nft;
        object::delete(id);
    }


    public entry fun update_nft_description(
        profile: &ProviderProfile,
        nft: &mut ExperienceNFT,
        new_description: vector<u8>,
        clock: &Clock, // <-- AÑADIDO
        ctx: &mut TxContext
    ) {
        assert!(object::id(profile) == nft.provider_id, E_UNAUTHORIZED);
        assert!(tx_context::sender(ctx) == profile.owner, E_UNAUTHORIZED);
         // --- AÑADIDO: Verificación de Expiración ---
        assert!(
            nft.expiration_timestamp_ms == 0 || clock::timestamp_ms(clock) < nft.expiration_timestamp_ms,
            E_UNAUTHORIZED // O un error E_EVENT_HAS_PASSED
        );
        nft.description = utf8(new_description);
        event::emit(NftUpdated {
            nft_id: object::id(nft),
            provider_id: object::id(profile)
        });
    }

    // Añade esta función dentro del módulo experience_nft
    public fun royalties(nft: &ExperienceNFT): &RoyaltyConfig {
        &nft.royalties
    }

    
    // --- AÑADE ESTA FUNCIÓN SI NO EXISTE ---
    public fun royalty_recipient(config: &RoyaltyConfig): address {
        config.recipient
    }

    /// Devuelve los puntos base de las regalías de una configuración.
    public fun royalty_basis_points(config: &RoyaltyConfig): u16 {
        config.basis_points
    }

    // --- FUNCIONES DE MARKETPLACE ---
    /// [PROVEEDOR] Pone a la venta un NFT por primera vez en SUI.
    public entry fun list_for_sale(
        provider_profile: &ProviderProfile, 
        nft: ExperienceNFT, 
        price_in_mist: u64, 
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verificación de que quien llama es el dueño del perfil de proveedor.
        assert!(tx_context::sender(ctx) == provider_profile.owner, E_UNAUTHORIZED);
        // Verificación de que el NFT no ha expirado.
        assert!(nft.expiration_timestamp_ms == 0 || clock::timestamp_ms(clock) < nft.expiration_timestamp_ms, E_UNAUTHORIZED);

        // Se crea el objeto `Listing`.
        let listing = Listing {
            id: object::new(ctx), 
            nft, 
            price: price_in_mist, 
            is_available: true,
            seller: provider_profile.owner, 
            provider_id: object::id(provider_profile),
            is_tkt_listing: false
        };

        // Se emite un evento para que el frontend pueda indexarlo.
        event::emit(NftListed {
            listing_id: object::id(&listing),
            nft_id: object::id(&listing.nft),
            price: price_in_mist,
            is_tkt_listing: false
        });

        // Se comparte el objeto `Listing` para que sea público en el marketplace.
        transfer::share_object(listing);
    }
    
    /// [PROVEEDOR] Pone a la venta un NFT por primera vez en TKT.
    public entry fun list_for_sale_tkt(
        provider_profile: &ProviderProfile, 
        nft: ExperienceNFT, 
        price_in_tkt_mist: u64, 
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verificación de que quien llama es el dueño del perfil de proveedor.
        assert!(tx_context::sender(ctx) == provider_profile.owner, E_UNAUTHORIZED);
        // Verificación de que el NFT no ha expirado.
        assert!(nft.expiration_timestamp_ms == 0 || clock::timestamp_ms(clock) < nft.expiration_timestamp_ms, E_UNAUTHORIZED);

        // Se crea el objeto `Listing`.
        let listing = Listing {
            id: object::new(ctx), 
            nft, 
            price: price_in_tkt_mist, 
            is_available: true,
            seller: provider_profile.owner, 
            provider_id: object::id(provider_profile),
            is_tkt_listing: true
        };

        // Se emite un evento para que el frontend pueda indexarlo.
        event::emit(NftListed {
            listing_id: object::id(&listing),
            nft_id: object::id(&listing.nft),
            price: price_in_tkt_mist,
            is_tkt_listing: true
        });

        // Se comparte el objeto `Listing` para que sea público en el marketplace.
        transfer::share_object(listing);
    }

    /// [USUARIO] Revende un NFT que posee en SUI.
    public entry fun list_for_resale(
        nft: ExperienceNFT, 
        price_in_mist: u64, 
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verificación de que el NFT no ha expirado.
        assert!(nft.expiration_timestamp_ms == 0 || clock::timestamp_ms(clock) < nft.expiration_timestamp_ms, E_UNAUTHORIZED);
        
        let sender = tx_context::sender(ctx);
        // Verificación clave: El revendedor NO debe ser el proveedor original.
        assert!(sender != nft.provider_address, E_UNAUTHORIZED);

        let provider_id = nft.provider_id;


        let listing = Listing {
            id: object::new(ctx), 
            nft, 
            price: price_in_mist, 
            is_available: true,
            seller: sender, 
            provider_id: provider_id,
            is_tkt_listing: false
        };

        event::emit(NftListed {
            listing_id: object::id(&listing),
            nft_id: object::id(&listing.nft),
            price: price_in_mist,
            is_tkt_listing: false
        });
        transfer::share_object(listing);
    }
    
    /// [USUARIO] Revende un NFT que posee en TKT.
    public entry fun list_for_resale_tkt(
        nft: ExperienceNFT, 
        price_in_tkt_mist: u64, 
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verificación de que el NFT no ha expirado.
        assert!(nft.expiration_timestamp_ms == 0 || clock::timestamp_ms(clock) < nft.expiration_timestamp_ms, E_UNAUTHORIZED);

        let sender = tx_context::sender(ctx);
        // Verificación clave: El revendedor NO debe ser el proveedor original.
        assert!(sender != nft.provider_address, E_UNAUTHORIZED);
        
        let provider_id = nft.provider_id;


        let listing = Listing {
            id: object::new(ctx), 
            nft, 
            price: price_in_tkt_mist, 
            is_available: true,
            seller: sender, 
            provider_id: provider_id,
            is_tkt_listing: true
        };
        
        event::emit(NftListed {
            listing_id: object::id(&listing),
            nft_id: object::id(&listing.nft),
            price: price_in_tkt_mist,
            is_tkt_listing: true
        });
        transfer::share_object(listing);
    }
    
    // --- MODIFICADO: `purchase` ahora distribuye comisiones ---
   public entry fun purchase(
        listing: Listing,
        vip_registry: &VipRegistry,
        staking_pool: &mut StakingPool, // Se usará para depositar las recompensas
        payment: Coin<SUI>, // Se recibe el objeto Coin completo
        ctx: &mut TxContext
    ) {
        assert!(!listing.is_tkt_listing, E_WRONG_CURRENCY);
        assert!(listing.is_available, E_LISTING_NOT_AVAILABLE);
        let price = listing.price;
        assert!(coin::value(&payment) >= price, E_INSUFFICIENT_FUNDS);

        let seller = listing.seller;
        
        // Se convierte la moneda de pago a un balance para poder dividirla
        let mut payment_balance = coin::into_balance(payment);

        // Se calcula la comisión
        let fee_rate = if (table::contains(&vip_registry.vips, seller)) { VIP_FEE_BASIS_POINTS } else { PLATFORM_FEE_BASIS_POINTS };
        let fee_amount = (price * fee_rate) / 10000;
        
        // Se separa la comisión del balance total
        let mut fee_balance = balance::split(&mut payment_balance, fee_amount);
        
        // El resto del balance (el pago principal) se convierte a Coin y va al vendedor
        transfer::public_transfer(coin::from_balance(payment_balance, ctx), seller);

        // --- CORRECCIÓN: La comisión en SUI se deposita en el pool de staking ---
        let fee_coin = coin::from_balance(fee_balance, ctx);
        deposit_rewards(staking_pool, fee_coin);
        
        // La transferencia del NFT y la creación del recibo se mantienen igual.
        transfer_nft_and_create_receipt(listing, tx_context::sender(ctx), ctx);
    }

    // --- MODIFICADO: `purchase_with_tkt` ahora implementa la distribución completa ---
    /// Permite a un usuario comprar un NFT listado en TKT, aplicando la tokenomics completa.
    public entry fun purchase_with_tkt(
        listing: Listing,
        vip_registry: &VipRegistry, // <-- AÑADIDO: Se recibe el registro de VIPs
        dao_treasury: &mut DAOTreasury,
        tkt_treasury_cap: &mut TreasuryCap<TKT>,
        payment: Coin<TKT>,
        ctx: &mut TxContext
    ) {
        // Verificaciones iniciales
        assert!(listing.is_tkt_listing, E_WRONG_CURRENCY);
        assert!(listing.is_available, E_LISTING_NOT_AVAILABLE);
        let price = listing.price;
        assert!(coin::value(&payment) >= price, E_INSUFFICIENT_FUNDS);

        // --- CORRECCIÓN: Se calcula la tasa de comisión dinámicamente ---
        // Se comprueba si el vendedor es VIP para aplicar un descuento.
        let fee_rate = if (table::contains(&vip_registry.vips, listing.seller)) {
            VIP_FEE_BASIS_POINTS // Tasa reducida para VIPs
        } else {
            PLATFORM_FEE_BASIS_POINTS // Tasa normal
        };
        let fee_amount = (price * fee_rate) / 10000;

        let mut payment_balance = coin::into_balance(payment);
        
        // Se separa la comisión del pago total
        let mut fee_balance = balance::split(&mut payment_balance, fee_amount);

        // El resto del pago va directamente al vendedor
        transfer::public_transfer(coin::from_balance(payment_balance, ctx), listing.seller);

        // --- Lógica del "Flywheel": Se distribuye la comisión en TKT ---
        let fee_value = balance::value(&fee_balance);
        
        // 40% de la comisión va a la Tesorería de la DAO (destinado a recompensas de staking en el futuro)
        let rewards_part = balance::split(&mut fee_balance, fee_value * 40 / 100);
        deposit_to_treasury(dao_treasury, coin::from_balance(rewards_part, ctx));
        
        // 30% de la comisión va a la Tesorería de la DAO (para operaciones)
        let dao_part = balance::split(&mut fee_balance, fee_value * 30 / 100);
        deposit_to_treasury(dao_treasury, coin::from_balance(dao_part, ctx));

        // El 30% restante de la comisión se quema, reduciendo la oferta total de TKT
        coin::burn(tkt_treasury_cap, coin::from_balance(fee_balance, ctx));

        // Se finaliza la transacción transfiriendo el NFT y creando el recibo
        transfer_nft_and_create_receipt(listing, tx_context::sender(ctx), ctx);
    }
    
    // --- FUNCIONES DE RESEÑAS Y FRACCIONAMIENTO ---

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

    public entry fun fractionize(
        nft: ExperienceNFT, 
        shares: vector<u64>, 
        recipients: vector<address>,
        clock: &Clock, // <-- AÑADIDO
        ctx: &mut TxContext
    ) {

         // --- AÑADIDO: Verificación de Expiración ---
        assert!(
            nft.expiration_timestamp_ms == 0 || clock::timestamp_ms(clock) < nft.expiration_timestamp_ms,
            E_UNAUTHORIZED // Puedes usar un código de error E_TICKET_EXPIRED
        );
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
                id: object::new(ctx), 
                parent_id, 
                share: owner_share,
                parent_name: parent_name, 
                parent_image_url: parent_image_url,
            };
            transfer::public_transfer(owner_fraction, owner);
        };
        
        let mut j = 0;
        while (j < shares_len) {
            let share = *vector::borrow(&shares, j);
            let recipient = *vector::borrow(&recipients, j);
            if (share > 0) {
                let fraction = Fraction {
                    id: object::new(ctx), 
                    parent_id, 
                    share,
                    parent_name: parent_name, 
                    parent_image_url: parent_image_url,
                };
                transfer::public_transfer(fraction, recipient);
            };
            j = j + 1;
        };
        
        event::emit(NftFractioned { 
            parent_id, 
            shares_created: shares_len
        });

        // Se quema el NFT original después de fraccionarlo
        let ExperienceNFT { 
    id, 
    name:_, 
    description:_, 
    image_url:_, 
    event_name:_, 
    event_city:_, 
    validity_details:_, 
    experience_type:_, 
    issuer_name:_, 
    tier:_, 
    serial_number:_, 
    attributes:_, 
    collection_name:_, 
    royalties:_, 
    provider_id: _, 
    provider_address: _,
    // --- LÍNEAS AÑADIDAS ---
    is_redeemable: _,
    expiration_timestamp_ms: _,
    evolution_rules: _
} = nft;
        object::delete(id);
    }

    // --- FUNCIONES INTERNAS (Helpers) ---
    
    
    

    fun transfer_nft_and_create_receipt(listing: Listing, buyer: address, ctx: &mut TxContext) {
        let listing_id = object::id(&listing);
        let provider_id = listing.provider_id;
        let nft_name_copy = listing.nft.name;
        let nft_image_url_copy = listing.nft.image_url;
        let Listing { id, nft, price: _, is_available: _, seller: _, provider_id: _, is_tkt_listing: _ } = listing;
        
        transfer::public_transfer(nft, buyer);
        
        let receipt = PurchaseReceipt {
            id: object::new(ctx), buyer, listing_id, provider_id, 
            nft_name: nft_name_copy, nft_image_url: nft_image_url_copy
        };
        transfer::public_transfer(receipt, buyer);
        object::delete(id);
    }
}
