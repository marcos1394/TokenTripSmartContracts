module tokentrip_staking::staking {
    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use sui::math;
    use sui::sui::SUI; 


    use tokentrip_token::tkt::TKT;

    // --- ERRORES ---
    const E_NOTHING_TO_CLAIM: u64 = 1;
    const E_RECEIPT_NOT_OWNED: u64 = 2;
    const E_POOL_IS_EMPTY: u64 = 3;
    const REWARD_PRECISION: u128 = 1_000_000_000_000; // 10^12 para alta precisión

    public struct STAKING has drop {} // <-- AÑADE ESTA LÍNEA


    // --- MODIFICADO: `StakingPool` con lógica de acumulación ---
    public struct StakingPool has key, store {
        id: UID,
        total_staked: Balance<TKT>,
        rewards: Balance<SUI>,
        // --- NUEVO ---
        rewards_per_second: u64, // Cuántos MIST de SUI se distribuyen por segundo
        last_update_timestamp_ms: u64, // Última vez que se actualizó el acumulador
        accumulated_rewards_per_share: u128, // Acumulador de recompensas por "acción" (share)
    }

    // --- MODIFICADO: `StakeReceipt` con deuda de recompensas ---
    public struct StakeReceipt has key, store {
        id: UID,
        staked_amount: u64, // Guardamos el valor, no el Balance
        owner: address,
        // --- NUEVO ---
        // Registra las recompensas que ya se le han asignado al usuario.
        // Se usa para calcular las nuevas recompensas pendientes.
        reward_debt: u128,
    }

    // --- FUNCIONES ---
   // --- FUNCIONES ---
    fun init(witness: STAKING, ctx: &mut TxContext) { // <-- Se cambia el primer parámetro
        let pool = StakingPool {
            id: object::new(ctx),
            total_staked: balance::zero(),
            rewards: balance::zero(),
            rewards_per_second: 3805175, 
            // Se usa el timestamp del epoch, disponible en el contexto de init
            last_update_timestamp_ms: tx_context::epoch_timestamp_ms(ctx), 
            accumulated_rewards_per_share: 0,
        };
        transfer::share_object(pool);
    }
    
    /// Deposita TKT en el pool y le da al usuario un recibo NFT.
    public entry fun stake(
        pool: &mut StakingPool,
        tkt_to_stake: Coin<TKT>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // 1. Se actualiza el pool para calcular las recompensas acumuladas hasta ahora.
        update_pool(pool, clock);

        // 2. Se procesa el depósito del usuario.
        let amount = coin::value(&tkt_to_stake);
        balance::join(&mut pool.total_staked, coin::into_balance(tkt_to_stake));
        
        // 3. Se crea el recibo para el usuario, calculando su "deuda" de recompensas inicial.
        let receipt = StakeReceipt {
            id: object::new(ctx),
            staked_amount: amount,
            owner: tx_context::sender(ctx),
            reward_debt: ((amount as u128) * pool.accumulated_rewards_per_share) / REWARD_PRECISION,
        };
        transfer::public_transfer(receipt, tx_context::sender(ctx));
    }

    /// Permite al usuario retirar sus TKT depositados, quemando el recibo.
    public entry fun unstake(
        pool: &mut StakingPool,
        receipt: StakeReceipt,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(receipt.owner == tx_context::sender(ctx), E_RECEIPT_NOT_OWNED);
        
        // 1. Se actualiza el pool para asegurar que los cálculos de recompensas estén al día.
        update_pool(pool, clock);
        
        // 2. Se calculan y se pagan las recompensas pendientes antes de retirar.
        let pending = pending_rewards(pool, &receipt);
        if (pending > 0) {
            let reward_payment = coin::take(&mut pool.rewards, pending, ctx);
            transfer::public_transfer(reward_payment, tx_context::sender(ctx));
        };

        // 3. Se retira el principal del usuario del pool.
        let staked_balance = balance::split(&mut pool.total_staked, receipt.staked_amount);
        let tkt_payment = coin::from_balance(staked_balance, ctx);
        transfer::public_transfer(tkt_payment, tx_context::sender(ctx));

        // 4. Se quema el recibo.
        let StakeReceipt { id, staked_amount: _, owner: _, reward_debt: _ } = receipt;
        object::delete(id);
    }

    /// Permite al usuario reclamar sus recompensas en SUI sin retirar su stake.
    public entry fun claim_rewards(
        pool: &mut StakingPool,
        receipt: &mut StakeReceipt,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // 1. Se actualiza el pool.
        update_pool(pool, clock);
        
        // 2. Se calculan las recompensas pendientes.
        let pending = pending_rewards(pool, receipt);
        assert!(pending > 0, E_NOTHING_TO_CLAIM);
        
        // 3. Se pagan las recompensas.
        let reward_payment = coin::take(&mut pool.rewards, pending, ctx);
        transfer::public_transfer(reward_payment, tx_context::sender(ctx));
        
        // 4. Se actualiza la "deuda" de recompensas del usuario para resetear el contador.
        receipt.reward_debt = (receipt.staked_amount as u128 * pool.accumulated_rewards_per_share) / 1_000_000_000;
    }

    // --- Funciones Internas y de Vista ---

    /// (Interna) La función clave que actualiza el estado del pool de recompensas.
    fun update_pool(pool: &mut StakingPool, clock: &Clock) {
        let now = clock::timestamp_ms(clock);
        let time_elapsed = now - pool.last_update_timestamp_ms;

        if (time_elapsed == 0) { return };
        
        let total_staked = balance::value(&pool.total_staked);
        if (total_staked == 0) {
            pool.last_update_timestamp_ms = now;
            return
        };

        let rewards_generated = ((time_elapsed as u128) * (pool.rewards_per_second as u128)) / 1000;
        pool.accumulated_rewards_per_share = pool.accumulated_rewards_per_share + ((rewards_generated * REWARD_PRECISION) / (total_staked as u128));
        pool.last_update_timestamp_ms = now;
    }

    /// (Pública de solo lectura) Calcula las recompensas pendientes para un recibo.
    public fun pending_rewards(pool: &StakingPool, receipt: &StakeReceipt): u64 {
        let expected_reward = ((receipt.staked_amount as u128) * pool.accumulated_rewards_per_share) / REWARD_PRECISION;
        (expected_reward - receipt.reward_debt) as u64
    }

    // --- Funciones de Gestión (requieren autorización, ej. desde la DAO) ---

    /// Permite depositar los fondos de SUI para las recompensas.
    public entry fun deposit_rewards(pool: &mut StakingPool, sui_funds: Coin<SUI>) {
        balance::join(&mut pool.rewards, coin::into_balance(sui_funds));
    }
    
    /// Permite a un admin o a la DAO ajustar la tasa de recompensas.
    public entry fun set_rewards_per_second(pool: &mut StakingPool, new_rate: u64, clock: &Clock) {
        // Primero actualizamos el pool con la tasa antigua.
        update_pool(pool, clock);
        // Luego establecemos la nueva tasa.
        pool.rewards_per_second = new_rate;
    }
}