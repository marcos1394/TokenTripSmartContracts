module tokentrip_staking::staking {
    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use std::option::{Self, Option};
    use sui::clock::{Self, Clock};

    use tokentrip_token::tkt::TKT;

    // --- ERRORES ---
    const E_NOTHING_TO_CLAIM: u64 = 1;
    const E_RECEIPT_NOT_OWNED: u64 = 2;

    // --- STRUCTS ---
    /// El objeto compartido que contiene todos los fondos y la lógica del staking.
    public struct StakingPool has key, store {
        id: UID,
        total_staked: Balance<TKT>,
        rewards: Balance<SUI> // Asumimos que las recompensas son en SUI
    }

    /// Un "recibo" NFT que representa el depósito de un usuario.
    public struct StakeReceipt has key, store {
        id: UID,
        staked_amount: Balance<TKT>,
        owner: address,
        staked_at_ms: u64
    }

    // --- FUNCIONES ---
    fun init(ctx: &mut TxContext) {
        let pool = StakingPool {
            id: object::new(ctx),
            total_staked: balance::zero(),
            rewards: balance::zero()
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
        let amount = coin::into_balance(tkt_to_stake);
        balance::join(&mut pool.total_staked, balance::copy(&amount));
        
        let receipt = StakeReceipt {
            id: object::new(ctx),
            staked_amount: amount,
            owner: tx_context::sender(ctx),
            staked_at_ms: clock::timestamp_ms(clock)
        };
        transfer::public_transfer(receipt, tx_context::sender(ctx));
    }

    /// Permite al usuario retirar sus TKT depositados, quemando el recibo.
    public entry fun unstake(
        pool: &mut StakingPool,
        receipt: StakeReceipt,
        ctx: &mut TxContext
    ) {
        assert!(receipt.owner == tx_context::sender(ctx), E_RECEIPT_NOT_OWNED);
        let StakeReceipt { id, staked_amount, owner: _, staked_at_ms: _ } = receipt;
        object::delete(id); // Se quema el recibo

        balance::join(&mut coin::balance_mut_for_testing(ctx), staked_amount);
    }

    /// Permite al usuario reclamar sus recompensas en SUI.
    public entry fun claim_rewards(
        pool: &mut StakingPool,
        receipt: &mut StakeReceipt,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // --- LÓGICA DE CÁLCULO DE RECOMPENSAS (Ejemplo) ---
        // Una implementación real sería más compleja.
        let rewards_to_claim = 1_000_000; // Ejemplo: 0.001 SUI
        assert!(balance::value(&pool.rewards) >= rewards_to_claim, E_NOTHING_TO_CLAIM);
        
        let reward_payment = coin::take(&mut pool.rewards, rewards_to_claim, ctx);
        transfer::public_transfer(reward_payment, tx_context::sender(ctx));
        
        receipt.staked_at_ms = clock::timestamp_ms(clock); // Se resetea el tiempo
    }

    /// Función para que el contrato del marketplace deposite las recompensas.
    public entry fun deposit_rewards(
        pool: &mut StakingPool,
        sui_funds: Coin<SUI>
    ) {
        balance::join(&mut pool.rewards, coin::into_balance(sui_funds));
    }
}
