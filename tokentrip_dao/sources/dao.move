// tokentrip_dao/sources/dao.move
module tokentrip_dao::dao {
use sui::object::{Self, ID, UID};
use sui::tx_context::{Self, TxContext};
use sui::transfer;
use sui::event;
use std::string::{String as StdString, utf8};
use sui::clock::{Self, Clock};
use sui::table::{Self, Table};
use tokentrip_token::tkt::TKT;
use sui::coin::{Self, Coin, destroy_zero};
use sui::balance::{Self, Balance};
// --- CÓDIGOS DE ERROR ---
const E_PROPOSAL_NOT_ACTIVE: u64 = 1;
const E_VOTING_PERIOD_NOT_ENDED: u64 = 2;
const E_PROPOSAL_ALREADY_EXECUTED: u64 = 3;
const E_VOTING_CLOSED: u64 = 4;
const E_ALREADY_VOTED: u64 = 5;
const E_PROPOSAL_FAILED: u64 = 6;
const VOTING_PERIOD_MS: u64 = 604_800_000; // 7 días en ms
// --- CONSTANTES ---
// Duración de la votación: 7 días en milisegundos
// --- STRUCTS ---
/// El objeto principal de la DAO, que se comparte y contiene todas las propuestas.
public struct DAO has key, store {
id: UID,
// Un contador para generar IDs únicos para cada propuesta.
proposal_count: u64
}
// --- NUEVO: El tesoro de la DAO ---
public struct DAOTreasury has key, store {
id: UID,
balance: Balance
}
// --- MODIFICADO: La propuesta ahora incluye una acción ---
public struct Proposal has key, store {
id: UID,
proposal_id: u64,
creator: address,
title: StdString,
description: StdString,
for_votes: u64,
against_votes: u64,
end_timestamp_ms: u64,
is_executed: bool,
voters: Table,
// Acción propuesta (para V1, una transferencia)
transfer_destination: address,
transfer_amount: u64
}
// --- EVENTOS ---
public struct ProposalCreated has copy, drop {
proposal_id: u64,
creator: address,
title: StdString,
end_timestamp_ms: u64
}
public struct VotedOnProposal has copy, drop {
proposal_id: u64,
voter: address,
vote_for: bool, // true si es a favor, false si es en contra
voting_power: u64, // Cantidad de TKT con la que se votó
}
public struct ProposalExecuted has copy, drop {
proposal_id: u64,
executed_by: address
}
// --- FUNCIONES ---
// La función de inicialización crea el objeto principal de la DAO
fun init(ctx: &mut TxContext) {
// Se crea y comparte el objeto principal de la DAO
let dao = DAO {
id: object::new(ctx),
proposal_count: 0
};
transfer::share_object(dao);
// CORRECCIÓN: Se crea Y SE COMPARTE el tesoro de la DAO
let treasury = DAOTreasury {
id: object::new(ctx),
balance: balance::zero()
};
transfer::share_object(treasury);
}
/// Permite a cualquier usuario crear una propuesta de gobernanza.
public entry fun create_proposal(
dao: &mut DAO,
title: vector,
description: vector,
transfer_destination: address,
transfer_amount: u64,
clock: &Clock,
ctx: &mut TxContext
) {
let sender = tx_context::sender(ctx);
dao.proposal_count = dao.proposal_count + 1;
let proposal_id = dao.proposal_count;
let end_time = clock::timestamp_ms(clock) + VOTING_PERIOD_MS;
let proposal = Proposal {
id: object::new(ctx), proposal_id, creator: sender,
title: utf8(title), description: utf8(description),
for_votes: 0, against_votes: 0, end_timestamp_ms: end_time,
is_executed: false, voters: table::new(ctx),
transfer_destination, transfer_amount
};
event::emit(ProposalCreated { proposal_id, creator: sender, title: proposal.title, end_timestamp_ms: end_time });
transfer::share_object(proposal);
}
// --- NUEVO: Función para ejecutar una propuesta ---
public entry fun execute_proposal(
proposal: &mut Proposal,
treasury: &mut DAOTreasury,
clock: &Clock,
ctx: &mut TxContext
) {
// Verificación 1: La votación debe haber terminado.
assert!(clock::timestamp_ms(clock) >= proposal.end_timestamp_ms, E_VOTING_PERIOD_NOT_ENDED);
// Verificación 2: La propuesta no debe haber sido ejecutada antes.
assert!(!proposal.is_executed, E_PROPOSAL_ALREADY_EXECUTED);
// Verificación 3: Los votos a favor deben ser mayores que los en contra.
assert!(proposal.for_votes > proposal.against_votes, E_PROPOSAL_FAILED);
// Se marca la propuesta como ejecutada.
proposal.is_executed = true;
// Se ejecuta la acción: transferir fondos del tesoro.
let amount_to_transfer = proposal.transfer_amount;
if (amount_to_transfer > 0) {
let funds = balance::split(&mut treasury.balance, amount_to_transfer);
let payment = coin::from_balance(funds, ctx);
transfer::public_transfer(payment, proposal.transfer_destination);
};
event::emit(ProposalExecuted {
proposal_id: proposal.proposal_id,
executed_by: tx_context::sender(ctx)
});
}
// Añade esta función en la sección de FUNCIONES
/// Permite a un poseedor de TKT votar en una propuesta activa.
public entry fun vote(
proposal: &mut Proposal,
tkt_coin: Coin, // La moneda que prueba el poder de voto
vote_for: bool,
clock: &Clock,
ctx: &mut TxContext
) {
let voter = tx_context::sender(ctx);
// Verificación 1: La propuesta debe estar activa (la votación no ha terminado)
assert!(clock::timestamp_ms(clock) < proposal.end_timestamp_ms, E_VOTING_CLOSED);
// Verificación 2: El usuario no puede votar dos veces en la misma propuesta
assert!(!table::contains(&proposal.voters, voter), E_ALREADY_VOTED);
// Se obtiene el poder de voto de la moneda presentada
let voting_power = coin::value(&tkt_coin);
// IMPORTANTE: Se devuelve la moneda al votante. No se gasta.
transfer::public_transfer(tkt_coin, voter);
// Se actualizan los contadores de votos
if (vote_for) {
proposal.for_votes = proposal.for_votes + voting_power;
} else {
proposal.against_votes = proposal.against_votes + voting_power;
};
// Se registra que esta dirección ya ha votado en esta propuesta
table::add(&mut proposal.voters, voter, true);
// Se emite el evento
event::emit(VotedOnProposal {
proposal_id: proposal.proposal_id,
voter,
vote_for,
voting_power
});
}
}
