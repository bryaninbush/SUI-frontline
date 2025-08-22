module frontline_game::events {
    use sui::event;

    /// 下單
    public struct BetPlaced has copy, drop, store { round: u64, player: address, a: u64, b: u64, c: u64 }

    /// 關盤
    public struct RoundClosed has copy, drop, store { round: u64, a_users: u64, b_users: u64, c_users: u64 }

    /// 領獎
    public struct Claimed has copy, drop, store { round: u64, player: address, reward: u64 }

    public fun emit_bet(round: u64, player: address, a: u64, b: u64, c: u64) {
        event::emit(BetPlaced { round, player, a, b, c });
    }

    public fun emit_close(round: u64, a_users: u64, b_users: u64, c_users: u64) {
        event::emit(RoundClosed { round, a_users, b_users, c_users });
    }

    public fun emit_claim(round: u64, player: address, reward: u64) {
        event::emit(Claimed { round, player, reward });
    }
}