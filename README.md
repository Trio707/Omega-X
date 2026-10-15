# Omega_X_EA

A MetaTrader 5 Expert Advisor implementing a **one-sided grid martingale** with a **straddle entry gate**, a **dynamic basket take-profit**, and a **multi-layer safety system**. Designed for **hedging accounts only**.

> ⚠️ **Risk warning:** This EA uses a martingale lot progression. Martingale strategies can — and eventually will — produce severe drawdowns or account loss if the market trends strongly against an open grid. Never run it on an account you cannot afford to lose. Test on demo first.

---

## Table of contents

- [Overview](#overview)
- [How it works](#how-it-works)
  - [1. Entry (straddle)](#1-entry-straddle)
  - [2. Grid management](#2-grid-management)
  - [3. Exit (basket TP)](#3-exit-basket-tp)
  - [4. Safety layer](#4-safety-layer)
- [Server-side basket TP](#server-side-basket-tp)
- [Requirements](#requirements)
- [Installation](#installation)
- [Input parameters](#input-parameters)
- [State machine](#state-machine)
- [Recovery after restart](#recovery-after-restart)
- [Logging](#logging)
- [Known limitations](#known-limitations)
- [Documented design decisions](#documented-design-decisions)
- [File info](#file-info)

---

## Overview

| Property | Value |
|---|---|
| Platform | MetaTrader 5 |
| Account type | **Hedging only** (netting is rejected at init) |
| Magic number | `892174` (hard-coded) |
| Strategy | One-sided grid martingale |
| Entry | Straddle of BuyStop + SellStop pendings |
| Exit | Broker-side basket TP **or** code-driven money TP — mutually exclusive, see below |
| Safety | Equity stop, daily loss stop, spread filter, session/news filter, lot caps |
| Timeframe | Any (indicator periods are user-set) |
| Symbol | Any (tested on FX and XAUUSD) |

The EA does **not** use per-order stop-loss or take-profit. It manages risk and exits at the **basket level**.

---

## How it works

### 1. Entry (straddle)

While flat, the EA measures a recent price range and places **two pending orders** simultaneously:

- **BuyStop** above the range.
- **SellStop** below the range.

The range can be measured two ways (see `StraddleRangeMode`):

- `RANGE_CANDLES` — high/low of the last N completed bars.
- `RANGE_PIPS` — fixed pip distance around the midpoint of the last N completed bars.

An optional **ATR width filter** (`UseRangeATRFilter`) blocks arming when the range is too wide relative to recent volatility.

Both pendings have an **expiry** (`StraddleExpiryBars` bars or `StraddleExpiryHours` hours, whichever comes first). When one fills, the other is cancelled and the grid begins.

### 2. Grid management

Once the first position is open, the trade direction is locked (level 1's side defines the direction of the entire grid).

When price moves **against** the grid by a configured step, a new level is added on the **same side** with a larger lot size. Level spacing can be:

- `SPACING_FIXED` — constant number of points.
- `SPACING_ATR` — ATR × multiplier, **frozen at level 1** (see design note #3).
- `SPACING_MULTIPLICATIVE` — geometric growth per level.

Lot sizes follow `BaseLot × LotMultiplier^(n-1)`, capped by `MaxLotSize` and by `MaxTotalLots`.

### 3. Exit (basket TP)

Every tick the EA recomputes the same money target:

```
target = totalLots × MoneyPerLotTP   (× TPDecayFactor^(levels-1) if UseTPDecay)
```

**How that target is realised depends on `UseServerSideBasketTP`** — the two mechanisms are mutually exclusive, not additive:

| `UseServerSideBasketTP` | Who closes the basket |
|---|---|
| `true` (default) | The **broker**, via a TP placed on every open order at the computed price. `ManageExits()` returns early, so the code-driven close never runs. |
| `false` | The **EA**, on the very tick the basket's floating P/L (profit + swap) reaches `target` — all positions closed at once. |

Consequences of leaving the default `true`:

- The exit is a **single deterministic price** rather than a floating-P/L threshold, so it cannot be missed by a slow tick or a slippage spike.
- The code-driven exit path is inactive, which also means `UsePartialClose` / `PartialCloseRatio` have **no effect**. Set `UseServerSideBasketTP = false` if you need partial closes.
- See [Server-side basket TP](#server-side-basket-tp) for the price computation and the dirty-grid caveat.

### 4. Safety layer

| Guard | Trigger | Action |
|---|---|---|
| `MaxTotalLots` | Sum of open lots | Blocks new grid levels above the cap |
| `MaxSpreadPoints` | Current spread | Blocks arming and grid adds |
| `EquityStopPercent` | Equity drop vs. start-of-day | Close all + halt until next broker day |
| `DailyLossPercent` | Equity drop vs. start-of-day | Close all + pause until next broker day |
| `UseSessionFilter` | Server hour outside window | Blocks **arming** only |
| `UseNewsFilter` | Local time inside blackout | Blocks **arming** only |
| `MaxGridLevels` | Open trade count | Blocks further grid adds |

Once halted (`g_halted = true`), the EA closes everything and stops arming or adding until the next broker server day.

---

## Server-side basket TP

The EA can mirror the money target onto every open order as a **server-side TP**, so the **broker** owns the exit. While this mode is active the code-driven close is disabled, which means the exit survives a dead EA: if it stops running (VPS dies, terminal crashes, internet drops), the broker still closes the basket on its own.

- Controlled by `UseServerSideBasketTP` (default `true`).
- The placed TP price is `BasketTPSafetyFactor` × the money target. The default is `1.0`, i.e. the TP sits **exactly** on the target price. Note that the price is rounded to the symbol's digits, so for a BUY basket the rounded TP may land marginally *nearer* than the exact target and realize slightly under it. Raise the factor (e.g. `1.05`) if you want a cushion against that rounding.
- Computed from the volume-weighted average entry of all open positions.
- **Recomputed every tick**, so new grid levels and dirty transitions are handled automatically.
- **Idempotent**: orders whose TP already matches (within half a point) are not re-modified, so a no-op tick issues no requests.
- **Not cleaned up on deinit** — the whole point is that the TP survives the EA's removal.
- Setting `UseServerSideBasketTP = false` restores the code-driven money close and disables all of the above.

To compute the TP, the EA uses `SYMBOL_TRADE_TICK_VALUE` and `SYMBOL_TRADE_TICK_SIZE` to convert the money target into a price distance. If either is unavailable or invalid, the server TP is skipped for that tick and retried later. If the computed price would fall inside the broker's `SYMBOL_TRADE_STOPS_LEVEL` / `SYMBOL_TRADE_FREEZE_LEVEL` distance, the EA **does not** move the TP closer to the market — it simply skips the tick and retries later, so the net never weakens the exit.

### ⚠️ Dirty grids have no exit

A **dirty grid** is one with positions on **both** the BUY and SELL side (this can happen via the straddle gap-through case, or if a hedge is placed manually). No single price can express the basket money target, so:

- `ClearBasketTP()` **strips** the server TP from every order, and
- `ManageExits()` returns early, so the code-driven close never runs.

The result is a basket that **nothing can close** except the `EquityStopPercent` / `DailyLossPercent` halts. The EA therefore emits a loud warning through `LogError` — printed regardless of `VerboseLog`, at most once per bar:

```
[GM] ERROR ... | DIRTY GRID HAS NO EXIT: 2 positions open on BOTH sides. The server-side TP was cleared ...
```

**Watch for that line.** Either close such a basket manually, or set `UseServerSideBasketTP = false` so the code-driven exit handles it again.

---

## Requirements

- **MetaTrader 5** (build 3xxx or newer).
- **Hedging account.** Netting accounts are rejected in `OnInit()`.
- The symbol must support pending **BuyStop/SellStop** orders.
- The symbol's `SYMBOL_TRADE_STOPS_LEVEL` and `SYMBOL_TRADE_FREEZE_LEVEL` are respected when placing straddles and server-side TPs.
- **AutoTrading enabled** in the terminal and permission for algorithmic trading on the account.

---

## Installation

1. Copy `Omega_X_EA.mq5` into `MQL5/Experts/` in your terminal's data folder.
2. Open **MetaEditor** and compile the file (F7).
3. In MetaTrader 5, open a chart of your target symbol and timeframe.
4. Drag the EA from the Navigator onto the chart.
5. Configure inputs (see [Input parameters](#input-parameters)).
6. Enable **Algo Trading**.

On first attach, the EA inspects live positions and pending orders and **recovers state automatically** (see [Recovery after restart](#recovery-after-restart)).

---

## Input parameters

### Grid Spacing

| Input | Default | Meaning |
|---|---|---|
| `SpacingMode` | `SPACING_FIXED` | Fixed / ATR / Multiplicative |
| `GridStepPoints` | 300 | Fixed mode: step distance in points |
| `ATRPeriod` | 14 | ATR mode: period |
| `ATRMultiplier` | 1.5 | ATR mode: step = ATR × this |
| `SpacingBasePoints` | 300 | Multiplicative: base step |
| `SpacingMultiplier` | 1.5 | Multiplicative: step_n = base × mult^(n-1) |

### Lot Progression

| Input | Default | Meaning |
|---|---|---|
| `BaseLot` | 0.01 | Level 1 volume |
| `LotMultiplier` | 1.5 | lot_n = BaseLot × mult^(n-1) |
| `MaxLotSize` | 10.0 | Hard cap per order |
| `MaxGridLevels` | 10 | Hard cap on open trades in one grid |

### Exit

| Input | Default | Meaning |
|---|---|---|
| `MoneyPerLotTP` | 10.0 | Basket TP = TotalLots × this |
| `UseTPDecay` | false | Shrink TP with depth |
| `TPDecayFactor` | 0.95 | Applied as factor^(levels-1) |
| `UsePartialClose` | false | Close oldest profitable trade at X% of target — **ignored while `UseServerSideBasketTP` is true** |
| `PartialCloseRatio` | 0.8 | 0..1 |
| `UseServerSideBasketTP` | true | Let the **broker** own the exit via a TP on every order; disables the code-driven close |
| `BasketTPSafetyFactor` | 1.0 | Server TP is this multiple of the money target (≥ 1.0, enforced at init) |

### Safety Layer

| Input | Default | Meaning |
|---|---|---|
| `MaxTotalLots` | 5.0 | Hard cap on summed grid lots |
| `EquityStopPercent` | 30.0 | Close all + halt if equity drops this % from start of day |
| `DailyLossPercent` | 10.0 | Close all + pause until next server day |
| `MaxSpreadPoints` | 50 | Do not arm / add above this spread |
| `UseNewsFilter` | false | Local time-window filter |
| `NewsBlackoutWindows` | "" | e.g. `"2026.01.15 14:30-15:30;..."` |
| `UseSessionFilter` | false | Enable session filter |
| `SessionStartHour` | 0 | Server time, inclusive |
| `SessionEndHour` | 24 | Server time, exclusive |

### Execution

| Input | Default | Meaning |
|---|---|---|
| `SlippagePoints` | 20 | Max deviation on market orders |
| `MaxRetries` | 3 | Attempts per order/cancel/close |
| `OrderRetryDelayMs` | 200 | Delay between retries |

### Housekeeping

| Input | Default | Meaning |
|---|---|---|
| `VerboseLog` | true | Enable detailed logging |

### Straddle Entry

| Input | Default | Meaning |
|---|---|---|
| `StraddleRangeMode` | `RANGE_CANDLES` | CANDLES or PIPS |
| `RangeLookbackCandles` | 20 | CANDLES: N completed bars for high/low |
| `RangeDistancePips` | 30.0 | PIPS: total distance between stops |
| `RangePipAnchorCandles` | 1 | PIPS: anchor = midpoint of last N bars |
| `UseRangeATRFilter` | true | Enable range width filter |
| `RangeATRPeriod` | 14 | ATR period for the filter |
| `RangeMaxATRMultiple` | 1.5 | Range must be ≤ ATR × this to arm |
| `StraddleExpiryBars` | 50 | Cancel pendings after N unfilled bars |
| `StraddleExpiryHours` | 4 | ... or after N hours |
| `StraddleRearmDelayBars` | 1 | Bars to wait after a close before re-arming |
| `StopLevelBufferPoints` | 5 | Extra points beyond broker min stop level |

---

## State machine

The EA runs a small explicit state machine derived from **live terminal data** every tick:

| State | Meaning |
|---|---|
| `STATE_IDLE` | Flat, nothing armed |
| `STATE_ARMED` | Both straddle pendings alive, flat |
| `STATE_IN_GRID` | One or more positions with magic `892174` open |

Transitions are logged. A position arriving without a matching pending (e.g. filled while the EA was offline) is treated as an "adoption": the EA manages it as grid level 1.

---

## Recovery after restart

On `OnInit`, the EA rebuilds its world from the live terminal:

- If positions exist, the EA cancels any stray pendings, reconstructs the grid levels, and resumes `STATE_IN_GRID`.
- If exactly two opposing pendings exist, the EA resumes `STATE_ARMED`.
- If one pending exists (or pendings are same-side), the EA cancels and starts in `STATE_IDLE`.
- If nothing exists, the EA starts in `STATE_IDLE` and arms a fresh straddle.

**ATR spacing on restart:** the fill-time ATR is unrecoverable after a restart. The EA falls back to the live completed-bar ATR and logs the substitution. See design note #3.

---

## Logging

All log lines start with `[GM]` for easy filtering. Set `VerboseLog = false` to suppress informational lines; errors are always printed.

Examples:

```
[GM] 2026.01.15 14:03:12 | Straddle armed: BuyStop 3204.80 / SellStop 3201.60 / mid 3203.20 / lot 0.01 / expiry 50 bars or 4 h.
[GM] 2026.01.15 14:15:01 | Grid level 2/10 added on SELL: lots=0.02, total lots=0.03.
[GM] 2026.01.15 14:33:40 | Server-side basket TP 3204.12 applied to 2 order(s).
[GM] 2026.01.15 15:01:08 | Basket closed. Levels: 3, Lots: 0.08, PL: 0.83 (target 0.80, closed 3 positions).
```

The last line is only produced when `UseServerSideBasketTP = false`; with the default `true` the broker closes the basket at the TP price and no such line appears.

Errors are prefixed with `ERROR` and always printed, regardless of `VerboseLog`:

```
[GM] ERROR 2026.01.15 15:22:44 | HALT TRIGGERED: Equity stop: equity 34950.12 <= 35000.00 (30.0% of 50000.00). ...
[GM] ERROR 2026.01.15 15:40:02 | DIRTY GRID HAS NO EXIT: 2 positions open on BOTH sides. The server-side TP was cleared ...
```

---

## Known limitations

1. **Martingale blowup risk.** Even with all safety nets active, a strong sustained trend can produce large drawdowns. The safety layer reduces — but does not eliminate — this risk.
2. **Frozen ATR after restart.** ATR-spacing grids cannot recover the fill-time ATR. They use the current ATR as a fallback.
3. **A dirty grid has no exit while the server-side TP is enabled.** With `UseServerSideBasketTP = true` (the default) and positions open on **both** sides, the server TP is stripped and the code-driven close is disabled — so only the `EquityStopPercent` / `DailyLossPercent` halts can close the basket. The EA logs a `DIRTY GRID HAS NO EXIT` error (once per bar, always printed) to make this impossible to miss, but it is still a state you must monitor. Set `UseServerSideBasketTP = false` to restore a code-driven exit for such baskets.
4. **No per-trade SL.** Positions rely entirely on the basket-level safety layer.
5. **Grid adds can fail under margin pressure.** If the broker rejects a grid add, the EA logs the error. See "Retry behavior" below.
6. **Symbol-dependent tick values.** On some brokers, `SYMBOL_TRADE_TICK_VALUE` semantics differ. If the server-side TP price ever looks wrong, inspect this first.
7. **`BasketTPSafetyFactor = 1.0` leaves no rounding cushion.** The TP price is rounded to the symbol's digits; for a BUY basket that can place the TP marginally nearer than the exact target, so the realized profit can come in just under `totalLots × MoneyPerLotTP`. Raise the factor if that matters.

### Retry behavior

`MaxRetries` bounds the attempts per operation, but a **failed grid add is not latched** — the next tick will retry as long as the trigger condition still holds. Under extreme margin conditions this can produce a rapid series of failed attempts until free margin or a halt condition stops it. Monitor logs if running unattended.

---

## Documented design decisions

1. **Straddle comment preservation.** MQL5 cannot edit `POSITION_COMMENT` after a fill, so a level-1 position keeps the straddle comment (`MG_Straddle_BuyStop`/`MG_Straddle_SellStop`). Level index falls back to open-time order.
2. **`floatingPL = POSITION_PROFIT + POSITION_SWAP`.** Commission is excluded. Adjust `MoneyPerLotTP` if your broker charges heavy swap or commissions.
3. **ATR snapshot frozen at level-1 fill.** After a restart, the fill-time ATR is unrecoverable; the live completed-bar ATR is used as a documented fallback.
4. **Session/news filters gate arming only.** Once a grid is committed, only the spread filter and halts can block new grid levels.
5. **`MaxTotalLots` enforcement.** The next lot is capped to the free headroom. If headroom is below the broker volume minimum, the level is skipped and logged.
6. **Re-arm delay.** `StraddleRearmDelayBars` is applied after a basket close, after pending expiry, and after stray-pending cleanup, to avoid churn within the same bar.
7. **Server-side basket TP owns the exit.** The money target is mirrored onto every open order as a TP at `BasketTPSafetyFactor` × the target price, anchored on the volume-weighted average entry. While this mode is enabled `ManageExits()` returns early, so the code-driven close cannot race the server TP and `UsePartialClose` is inert. One deterministic exit price, and the basket still closes if the EA stops running. Deliberately **not** cleaned up on deinit, and disabled on dirty grids.
8. **Dirty grids are reported loudly.** On a dirty grid (positions on both sides) the server TP is stripped and the code-driven exit is disabled, leaving only the equity/daily-loss halts. `WarnDirtyGridExitless()` emits this via `LogError` — always printed, throttled to once per bar — so a gap-through or manually hedged basket cannot sit unnoticed.

---

## File info

| Field | Value |
|---|---|
| Filename | `Omega_X_EA.mq5` |
| Author | Omega X |
| Version | 1.10 |
| Magic number | `892174` |
| Platform | MetaTrader 5 |
| Account type | Hedging only |

---

## Disclaimer

This software is provided as-is, with no warranty of profitability or fitness for any particular purpose. Trading leveraged instruments carries substantial risk of loss. **You are solely responsible for any trades placed by this EA.** Backtest and forward-test on demo before risking real capital.
