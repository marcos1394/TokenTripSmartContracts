// en tokentrip_token/sources/tkt.move

module tokentrip_token::tkt {
    use std::option;
    use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// El struct del token TKT. Es un "One-Time Witness", una prueba
    /// de que este módulo se ha inicializado, garantizando que solo ocurra una vez.
    public struct TKT has drop {}

    /// La función de inicialización que se ejecuta una sola vez al publicar el paquete.
    fun init(witness: TKT, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency<TKT>(
            witness,
            9,                               // Decimales: 9 (como SUI)
            b"TKT",                          // Símbolo
            b"TokenTrip Token",               // Nombre completo
            b"El token de gobernanza y utilidad del ecosistema TokenTrip.", // Descripción
            option::some(sui::url::new_unsafe_from_bytes(b"https://cdn.tokentrip.com/tkt_logo.png")), // URL del ícono (reemplazar con la real)
            ctx
        );

        // Se transfiere la capacidad de acuñar (mint) nuevos tokens al publicador del contrato.
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));

        // Se transfiere el objeto de metadatos (información del token) al publicador.
        transfer::public_transfer(metadata, tx_context::sender(ctx));
    }
}
