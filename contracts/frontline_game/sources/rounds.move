module frontline_game::rounds {
    use std::vector;
    use sui::tx_context::{Self, TxContext, sender};
    use sui::object::{Self, UID};
    use sui::coin::{Self, Coin};
    use sui::balance;
    use sui::transfer;

    /*********************
     *  Constants
     *********************/
    const BPS: u64 = 10_000;          // 100%
    const HALF: u64 = 5_000;          // 0.5x
    const ONE: u64 = 10_000;          // 1.0x
    const DOUBLE: u64 = 20_000;       // 2.0x

    // base points per 1 token staked in each pool
    const POOL_A_BASE: u64 = 30;
    const POOL_B_BASE: u64 = 40;
    const POOL_C_BASE: u64 = 50;

    /*********************
     *  Marker type for SUI balance
     *********************/
    public struct SUI has drop {}

    /*********************
     *  Round & Player state
     *********************/
    /// Global round object (one per live round)
    public struct Round has key {
        id: UID,
        index: u64,                         // round number
        open: bool,                         // whether the round accepts stakes
        a_users: vector<address>,           // unique addresses per pool
        b_users: vector<address>,
        c_users: vector<address>,
        total_points: u128,                 // sum of computed points across players
        vault: balance::Balance<SUI>,       // accumulated SUI for this round
    }

    /// Per-player per-round state (each player creates one for the round)
    public struct PlayerRound has key {
        id: UID,
        round: u64,
        player: address,
        a_amount: u64,
        b_amount: u64,
        c_amount: u64,
        points: u128,                       // finalized points for this player (0 until computed)
        claimed: bool,
    }

    /*********************
     *  Lifecycle
     *********************/
    /// Module init hook (runs on publish/upgrade). Must be internal and return () in Move 2024.
    fun init(_ctx: &mut TxContext) {}

    /// Create a new Round object (call when you need a fresh Round resource).
    public entry fun create_round(ctx: &mut TxContext): Round {
        Round {
            id: object::new(ctx),
            index: 0,
            open: false,
            a_users: vector::empty<address>(),
            b_users: vector::empty<address>(),
            c_users: vector::empty<address>(),
            total_points: 0,
            vault: balance::zero<SUI>(),
        }
    }

    /// Start a new round. Requires mutable reference to the Round object.
    public entry fun open_round(rd: &mut Round) {
        assert!(!rd.open, 1); // E_ROUND_ALREADY_OPEN
        rd.index = rd.index + 1;
        rd.open = true;
        rd.a_users = vector::empty<address>();
        rd.b_users = vector::empty<address>();
        rd.c_users = vector::empty<address>();
        rd.total_points = 0;
    }

    /// Close the current round (stop accepting stakes).
    public entry fun close_round(rd: &mut Round) {
        assert!(rd.open, 2); // E_ROUND_CLOSED
        rd.open = false;
    }

    /*********************
     *  Player objects
     *********************/
    /// Create a PlayerRound for the current round. Each player should have at most one.
    public entry fun init_player_round(round_index: u64, ctx: &mut TxContext): PlayerRound {
        PlayerRound {
            id: object::new(ctx),
            round: round_index,
            player: sender(ctx),
            a_amount: 0,
            b_amount: 0,
            c_amount: 0,
            points: 0,
            claimed: false,
        }
    }

    /*********************
     *  Staking & Points
     *********************/
    /// Stake SUI into pools A/B/C in a single transaction.
    /// `payment` total must equal a + b + c.
    public entry fun stake(
        rd: &mut Round,
        mut payment: Coin<SUI>,
        a: u64, b: u64, c: u64,
        pr: &mut PlayerRound,
        ctx: &mut TxContext,
    ) {
        assert!(rd.open, 3); // E_ROUND_NOT_OPEN
        let total = coin::value(&payment);
        assert!(total == a + b + c && total > 0, 4); // E_BAD_AMOUNT
        assert!(pr.round == rd.index, 5);            // E_ROUND_MISMATCH
        assert!(pr.a_amount + pr.b_amount + pr.c_amount == 0, 6); // E_ALREADY_STAKED (simple single-shot)

        // Move funds into the round vault
        let bal = coin::into_balance(payment);
        balance::join(&mut rd.vault, bal);

        let who = sender(ctx);
        if (a > 0) { push_unique(&mut rd.a_users, who); }
        if (b > 0) { push_unique(&mut rd.b_users, who); }
        if (c > 0) { push_unique(&mut rd.c_users, who); }

        pr.a_amount = a; pr.b_amount = b; pr.c_amount = c;
    }

    /// Compute and write the player's points once the round is closed.
    /// Safe to call multiple times; only the first call writes points.
    public fun compute_points(rd: &Round, pr: &mut PlayerRound) {
        assert!(!rd.open, 7); // E_ROUND_STILL_OPEN
        if (pr.points != 0) { return; }

        let a_users = vector::length(&rd.a_users) as u64;
        let b_users = vector::length(&rd.b_users) as u64;
        let c_users = vector::length(&rd.c_users) as u64;
        let (a_mul, b_mul, c_mul) = popularity_multipliers(a_users, b_users, c_users);

        let a_pts = pool_points(pr.a_amount, POOL_A_BASE, a_mul);
        let b_pts = pool_points(pr.b_amount, POOL_B_BASE, b_mul);
        let c_pts = pool_points(pr.c_amount, POOL_C_BASE, c_mul);
        pr.points = a_pts + b_pts + c_pts;
    }

    /// Claim reward proportional to points. Platform fee (bps) goes to the caller (admin) for now.
    public entry fun claim(
        rd: &mut Round,
        pr: &mut PlayerRound,
        fee_bps: u64,
        ctx: &mut TxContext,
    ) {
        assert!(!rd.open, 8);         // E_ROUND_STILL_OPEN
        assert!(!pr.claimed, 9);      // E_ALREADY_CLAIMED
        if (pr.points == 0) { pr.claimed = true; return } // nothing to claim

        let vault_total = balance::value(&rd.vault);
        if (vault_total == 0) { pr.claimed = true; return }

        // lazy total_points: if zero, treat as this player's points (minimal demo)
        let total_pts = if (rd.total_points == 0) pr.points else rd.total_points;

        // fee
        let fee_amt: u64 = vault_total * fee_bps / BPS;
        let (fee_bal, remain) = balance::split(&mut rd.vault, fee_amt);
        rd.vault = remain;
        let fee_coin = coin::from_balance(fee_bal, ctx);
        transfer::public_transfer(fee_coin, sender(ctx));

        // payout
        let payout_pool = balance::value(&rd.vault);
        let reward_amt: u64 = (payout_pool as u128 * pr.points / total_pts) as u64;
        let (reward_bal, remain2) = balance::split(&mut rd.vault, reward_amt);
        rd.vault = remain2;
        let out = coin::from_balance(reward_bal, ctx);
        transfer::public_transfer(out, pr.player);

        pr.claimed = true;
    }

    /*********************
     *  Helpers
     *********************/
    fun push_unique(v: &mut vector<address>, who: address) {
        let n = vector::length(v);
        let mut i = 0;
        while (i < n) {
            if (*vector::borrow(v, i) == who) { return }
            i = i + 1;
        };
        vector::push_back(v, who);
    }

    fun popularity_multipliers(a_users: u64, b_users: u64, c_users: u64): (u64, u64, u64) {
        let maxv = max3(a_users, b_users, c_users);
        let minv = min3(a_users, b_users, c_users);
        let a_mul = if (a_users == maxv) HALF else if (a_users == minv) DOUBLE else ONE;
        let b_mul = if (b_users == maxv) HALF else if (b_users == minv) DOUBLE else ONE;
        let c_mul = if (c_users == maxv) HALF else if (c_users == minv) DOUBLE else ONE;
        (a_mul, b_mul, c_mul)
    }

    fun pool_points(amount: u64, base_per_token: u64, pool_mul_bps: u64): u128 {
        if (amount == 0) { return 0; }
        let base: u128 = (amount as u128) * (base_per_token as u128);
        let total = base * (pool_mul_bps as u128) / (BPS as u128);
        total
    }

    fun max3(a: u64, b: u64, c: u64): u64 { let m = if (a > b) a else b; if (m > c) m else c }
    fun min3(a: u64, b: u64, c: u64): u64 { let m = if (a < b) a else b; if (m < c) m else c }

    /*********************
     *  Simple ping (kept)
     *********************/
    public fun ping(): bool { true }
}
