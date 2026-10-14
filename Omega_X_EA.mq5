//+------------------------------------------------------------------+
//|                                             Omega_X_EA.mq5       |
//|  One-sided grid martingale EA with a straddle entry gate.         |
//|  Platform: MetaTrader 5.  Accounts: HEDGING only.                 |
//|  Magic: 892174 (hard-coded).                                      |
//|                                                                  |
//|  Documented decisions (see also the per-function headers):       |
//|   1. A level-1 position keeps the straddle comment                |
//|      ("MG_Straddle_BuyStop"/"MG_Straddle_SellStop") because MQL5  |
//|      cannot edit POSITION_COMMENT after a fill, therefore the     |
//|      level index falls back to open-time order.                   |
//|   2. floatingPL = POSITION_PROFIT + POSITION_SWAP. Commission is |
//|      reported separately by most brokers and is NOT included;     |
//|      adjust MoneyPerLotTP if your broker charges heavy swap.      |
//|   3. The ATR snapshot for SPACING_ATR is frozen at level-1 fill.  |
//|      After a restart the fill-time ATR is unrecoverable, so the   |
//|      live completed-bar ATR is used as a documented fallback.     |
//|   4. Session/news filters gate STRADDLE ARMING only. Once a grid  |
//|      is committed only the spread filter and halts can block new  |
//|      grid levels.                                                 |
//|   5. MaxTotalLots is enforced by capping the next lot to the free |
//|      headroom; if headroom < broker volume minimum the level is    |
//|      skipped and logged.                                          |
//|   6. Re-arm delay (StraddleRearmDelayBars) is applied after a     |
//|      basket close, after pending expiry and after stray-pending   |
//|      cleanup, to avoid re-arm churn inside the same bar.          |
//|   7. Server-side basket TP (UseServerSideBasketTP) mirrors the code-driven
//|      money target onto every open order at a safety-factor-multiplied price.
//|      Purpose: if the EA stops running, the broker still closes the basket.
//|      It is deliberately NOT cleaned up on deinit. Disabled on dirty grids.
//+------------------------------------------------------------------+
#property copyright "Omega X"
#property link      ""
#property version   "1.00"
#property description "One-sided grid martingale with straddle entry, dynamic basket TP and a safety layer. Hedging only."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//|  Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_SPACING_MODE
  {
   SPACING_FIXED,            // step = GridStepPoints * _Point
   SPACING_ATR,              // step = ATR(ATRPeriod) * ATRMultiplier, frozen at level 1
   SPACING_MULTIPLICATIVE    // step = SpacingBasePoints * _Point * SpacingMultiplier^(N-1)
  };

enum ENUM_RANGE_MODE
  {
   RANGE_CANDLES,            // range = high/low of the last RangeLookbackCandles completed bars
   RANGE_PIPS                // range = RangeDistancePips around the midpoint of an anchor range
  };

enum ENUM_STRADDLE_STATE
  {
   STATE_IDLE,               // flat, nothing armed
   STATE_ARMED,              // both straddle pendings alive, flat
   STATE_IN_GRID             // one or more positions with magic 892174 open
  };

//+------------------------------------------------------------------+
//|  Named constants                                                  |
//+------------------------------------------------------------------+
const ulong          EA_MAGIC              = 892174;   // hard-coded magic of this EA
const string         LEVEL_COMMENT_PREFIX  = "MG_Grid_Level";
const string         BUYSTOP_COMMENT       = "MG_Straddle_BuyStop";
const string         SELLSTOP_COMMENT      = "MG_Straddle_SellStop";
const double         POINTS_PER_PIP        = 10.0;     // spec convention: 1 pip == 10 points
const double         PERCENT_UNIT          = 100.0;
const int            SECONDS_PER_HOUR      = 3600;
const int            SECONDS_PER_DAY       = 86400;
const int            BARS_OUTSIDE_HISTORY  = 1000000;  // sentinel when a bar cannot be located
const int            MIN_LOOKBACK_BARS     = 1;
const int            MIN_GRID_LEVELS       = 1;
const double         LOT_TOLERANCE         = 0.000001; // FP guard for floor(volume/step) and lot sums
const int            LOT_DECIMALS          = 8;        // normalization precision for volumes

//+------------------------------------------------------------------+
//|  Grid level description (rebuilt from live data on every tick)    |
//+------------------------------------------------------------------+
struct GridLevel
  {
   ulong              ticket;      // position ticket
   int                level;       // grid level index (1-based)
   double             price;       // open price
   double             lots;        // volume
   datetime           openTime;    // position open time
   ENUM_POSITION_TYPE side;        // BUY or SELL
  };

//+------------------------------------------------------------------+
//|  Input parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Grid Spacing ==="
input ENUM_SPACING_MODE SpacingMode     = SPACING_FIXED;
input double         GridStepPoints     = 300;      // FIXED: distance between levels in points
input int            ATRPeriod          = 14;       // ATR mode: period
input double         ATRMultiplier      = 1.5;      // ATR mode: step = ATR * this (frozen at level 1)
input double         SpacingBasePoints  = 300;      // MULTIPLICATIVE: base step in points
input double         SpacingMultiplier  = 1.5;      // MULTIPLICATIVE: step_n = base * mult^(n-1)

input group "=== Lot Progression ==="
input double         BaseLot            = 0.01;     // level 1 volume
input double         LotMultiplier      = 1.5;      // lot_n = BaseLot * LotMultiplier^(n-1)
input double         MaxLotSize         = 10.0;     // hard cap per order
input int            MaxGridLevels      = 10;       // hard cap on open trades in one grid

input group "=== Exit ==="
input double         MoneyPerLotTP      = 10.0;     // basket TP = TotalLots * this (account currency)
input bool           UseTPDecay         = false;    // shrink TP with depth
input double         TPDecayFactor      = 0.95;     // applied as factor^(levels-1)
input bool           UsePartialClose    = false;    // close oldest profitable trade at X% of target
input double         PartialCloseRatio  = 0.8;      // 0..1
input bool           UseServerSideBasketTP = true;   // Place computed TP on all basket orders (crash safety net)
input double         BasketTPSafetyFactor  = 1.10;   // Server TP is this multiple of the code target (>= 1.0)

input group "=== Safety Layer ==="
input double         MaxTotalLots       = 5.0;      // hard cap on summed grid lots
input double         EquityStopPercent  = 30.0;     // close all + halt if equity drops this % from start of day
input double         DailyLossPercent   = 10.0;     // close all + pause until next server day
input int            MaxSpreadPoints    = 50;       // do not arm / add above this spread
input bool           UseNewsFilter      = false;    // local time-window filter (no external calls)
input string         NewsBlackoutWindows = "";      // e.g. "2026.01.15 14:30-15:30;2026.02.02 10:00-10:45"
input bool           UseSessionFilter   = false;
input int            SessionStartHour   = 0;        // server time, inclusive
input int            SessionEndHour     = 24;       // server time, exclusive

input group "=== Execution ==="
input int            SlippagePoints     = 20;
input int            MaxRetries         = 3;
input ulong          OrderRetryDelayMs  = 200;

input group "=== Housekeeping ==="
input bool           VerboseLog         = true;

input group "=== Straddle Entry ==="
input ENUM_RANGE_MODE StraddleRangeMode     = RANGE_CANDLES;
input int            RangeLookbackCandles   = 20;     // CANDLES: N completed bars for high/low
input double         RangeDistancePips      = 30.0;   // PIPS: total distance between the two stops
input int            RangePipAnchorCandles  = 1;      // PIPS: anchor = midpoint of last N completed bars
input bool           UseRangeATRFilter      = true;
input int            RangeATRPeriod         = 14;
input double         RangeMaxATRMultiple    = 1.5;    // range must be <= ATR * this to arm
input int            StraddleExpiryBars     = 50;     // cancel pendings after N unfilled bars
input int            StraddleExpiryHours    = 4;      // ... or after N hours, whichever comes first
input int            StraddleRearmDelayBars = 1;      // bars to wait after a basket close before re-arming
input int            StopLevelBufferPoints  = 5;      // extra points beyond broker min stop level

//+------------------------------------------------------------------+
//|  Globals                                                          |
//+------------------------------------------------------------------+
GridLevel g_grid[];              // live positions with magic 892174, sorted by open time ascending
CTrade    g_trade;               // execution helper

int      g_handleGridATR        = INVALID_HANDLE;  // ATR for grid spacing (SPACING_ATR only)
int      g_handleRangeATR       = INVALID_HANDLE;  // ATR for range validity filter
bool     g_halted               = false;          // equity stop / daily loss halt
string   g_haltReason           = "";
double   g_startOfDayEquity     = 0.0;            // equity snapshot at server day start
int      g_serverDayIndex       = 0;              // broker server day marker
double   g_gridATR              = 0.0;            // ATR frozen at level-1 fill
bool     g_gridATRSet           = false;
bool     g_gridDirty            = false;          // positions on both sides: exits only
datetime g_armTime              = 0;              // straddle arm time (expiry reference)
double   g_armMid               = 0.0;            // straddle midpoint (gap-through tie-break)
ulong    g_buyStopTicket        = 0;              // live BuyStop ticket of the armed straddle
ulong    g_sellStopTicket       = 0;              // live SellStop ticket of the armed straddle
ENUM_STRADDLE_STATE g_state     = STATE_IDLE;     // last processed state (transition logging only)
datetime g_lastCloseBar         = 0;              // bar time of the last basket close / cancel
datetime g_lastSkipBar          = 0;              // bar time of the last throttled "skip" log

//+------------------------------------------------------------------+
//|  Small formatting / logging helpers                               |
//+------------------------------------------------------------------+
//--- PriceStr : formats a price with the symbol digits.
//--- price : price value. Returns: string representation.
string PriceStr(const double price)
  {
   return DoubleToString(price, _Digits);
  }

//--- TicketStr : formats a 64-bit ticket for PrintFormat ("%.0f" avoids long-long format specifiers).
//--- ticket : ticket number. Returns: string representation.
string TicketStr(const ulong ticket)
  {
   return DoubleToString((double)ticket, 0);
  }

//--- StateName : human readable state name.
//--- state : state value. Returns: string name.
string StateName(const ENUM_STRADDLE_STATE state)
  {
   switch(state)
     {
      case STATE_IDLE:    return "IDLE";
      case STATE_ARMED:   return "ARMED";
      case STATE_IN_GRID:  return "IN_GRID";
      default:            return "UNKNOWN";
     }
  }

//--- PositionSideStr : human readable position side.
//--- side : position type. Returns: "BUY" or "SELL".
string PositionSideStr(const ENUM_POSITION_TYPE side)
  {
   return (side == POSITION_TYPE_BUY) ? "BUY" : "SELL";
  }

//--- LogInfo : verbose-only log line with timestamp and equity.
//--- msg : message body. Returns: void.
void LogInfo(const string msg)
  {
   if(!VerboseLog)
      return;
   PrintFormat("[GM] %s | %s | equity=%.2f balance=%.2f",
               TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
               msg,
               AccountInfoDouble(ACCOUNT_EQUITY),
               AccountInfoDouble(ACCOUNT_BALANCE));
  }

//--- LogError : always-printed log line with timestamp and equity.
//--- msg : message body. Returns: void.
void LogError(const string msg)
  {
   PrintFormat("[GM] ERROR %s | %s | equity=%.2f balance=%.2f",
               TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
               msg,
               AccountInfoDouble(ACCOUNT_EQUITY),
               AccountInfoDouble(ACCOUNT_BALANCE));
  }

//--- LogSkip : throttled "blocked action" log (once per bar) to keep verbose logs readable.
//--- msg : message body. Returns: void.
void LogSkip(const string msg)
  {
   if(!VerboseLog)
      return;
   datetime bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bar == g_lastSkipBar)
      return;
   g_lastSkipBar = bar;
   LogInfo(msg);
  }

//--- LogTransition : logs a state machine transition.
//--- from : previous state.  to : new state.  Returns: void.
void LogTransition(const ENUM_STRADDLE_STATE from, const ENUM_STRADDLE_STATE to)
  {
   LogInfo(StringFormat("[GM] STATE: %s -> %s", StateName(from), StateName(to)));
  }

//--- FailInit : reports an initialization failure and returns false.
//--- msg : reason. Returns: false.
bool FailInit(const string msg)
  {
   Print("[GM] INIT FAILED: " + msg);
   return false;
  }

//+------------------------------------------------------------------+
//|  Time helpers                                                     |
//+------------------------------------------------------------------+
//--- ServerTimeNow : current time expressed in broker server clock terms.
//--- Returns: server datetime (falls back to TimeCurrent when unavailable).
datetime ServerTimeNow()
  {
   datetime t = TimeTradeServer();
   if(t <= 0)
      t = TimeCurrent();
   return t;
  }

//--- ServerDayIndex : integer marker of the current broker server day.
//--- Returns: day index (seconds / SECONDS_PER_DAY).
int ServerDayIndex()
  {
   return (int)((long)ServerTimeNow() / SECONDS_PER_DAY);
  }

//--- CurrentBarTime : open time of the current chart bar.
//--- Returns: bar open time (0 on failure).
datetime CurrentBarTime()
  {
   return iTime(_Symbol, PERIOD_CURRENT, 0);
  }

//--- BarsSinceTime : number of bars elapsed since a given moment.
//--- t : reference time (0 returns BARS_OUTSIDE_HISTORY).
//--- Returns: bar index of t; BARS_OUTSIDE_HISTORY when the bar is not in loaded history.
int BarsSinceTime(const datetime t)
  {
   if(t <= 0)
      return BARS_OUTSIDE_HISTORY;
   int idx = iBarShift(_Symbol, PERIOD_CURRENT, t, false);
   if(idx < 0)
      return BARS_OUTSIDE_HISTORY;
   return idx;
  }

//--- HoursSince : elapsed hours since a given moment.
//--- t : reference time. Returns: elapsed hours (0.0 when t is invalid).
double HoursSince(const datetime t)
  {
   if(t <= 0)
      return 0.0;
   return (double)((long)TimeCurrent() - (long)t) / (double)SECONDS_PER_HOUR;
  }

//+------------------------------------------------------------------+
//|  Validation                                                       |
//+------------------------------------------------------------------+
//--- ValidateInputs : sanity checks for every tunable that could break the math.
//--- Returns: true when the configuration is safe to run.
bool ValidateInputs()
  {
   if(MaxGridLevels < MIN_GRID_LEVELS)
      return FailInit("MaxGridLevels must be >= 1.");
   if(BaseLot <= 0.0)
      return FailInit("BaseLot must be > 0.");
   if(LotMultiplier <= 0.0)
      return FailInit("LotMultiplier must be > 0.");
   if(MaxLotSize <= 0.0)
      return FailInit("MaxLotSize must be > 0.");
   if(MaxTotalLots <= 0.0)
      return FailInit("MaxTotalLots must be > 0.");
   if(MoneyPerLotTP <= 0.0)
      return FailInit("MoneyPerLotTP must be > 0.");
   if(EquityStopPercent <= 0.0 || EquityStopPercent >= PERCENT_UNIT)
      return FailInit("EquityStopPercent must be within (0,100).");
   if(DailyLossPercent <= 0.0 || DailyLossPercent >= PERCENT_UNIT)
      return FailInit("DailyLossPercent must be within (0,100).");
   if(MaxSpreadPoints <= 0)
      return FailInit("MaxSpreadPoints must be > 0.");
   if(StopLevelBufferPoints < 0)
      return FailInit("StopLevelBufferPoints must be >= 0.");
   if(SlippagePoints < 0)
      return FailInit("SlippagePoints must be >= 0.");
   if(MaxRetries < 1)
      return FailInit("MaxRetries must be >= 1.");

   if(SpacingMode == SPACING_FIXED && GridStepPoints <= 0.0)
      return FailInit("GridStepPoints must be > 0 in SPACING_FIXED mode.");
   if(SpacingMode == SPACING_ATR)
     {
      if(ATRPeriod < 1)
         return FailInit("ATRPeriod must be >= 1 in SPACING_ATR mode.");
      if(ATRMultiplier <= 0.0)
         return FailInit("ATRMultiplier must be > 0 in SPACING_ATR mode.");
     }
   if(SpacingMode == SPACING_MULTIPLICATIVE)
     {
      if(SpacingBasePoints <= 0.0 || SpacingMultiplier <= 0.0)
         return FailInit("SpacingBasePoints and SpacingMultiplier must be > 0 in SPACING_MULTIPLICATIVE mode.");
     }

   if(UseTPDecay && !(TPDecayFactor > 0.0))
      return FailInit("TPDecayFactor must be > 0 when UseTPDecay is enabled.");
   if(UsePartialClose && (PartialCloseRatio <= 0.0 || PartialCloseRatio > 1.0))
      return FailInit("PartialCloseRatio must be within (0,1] when UsePartialClose is enabled.");
   if(UseServerSideBasketTP && !(BasketTPSafetyFactor >= 1.0))
      return FailInit("BasketTPSafetyFactor must be >= 1.0 when UseServerSideBasketTP is enabled.");

   if(StraddleRangeMode == RANGE_CANDLES && RangeLookbackCandles < MIN_LOOKBACK_BARS)
      return FailInit("RangeLookbackCandles must be >= 1 in RANGE_CANDLES mode.");
   if(StraddleRangeMode == RANGE_PIPS)
     {
      if(RangePipAnchorCandles < MIN_LOOKBACK_BARS)
         return FailInit("RangePipAnchorCandles must be >= 1 in RANGE_PIPS mode.");
      if(RangeDistancePips <= 0.0)
         return FailInit("RangeDistancePips must be > 0 in RANGE_PIPS mode.");
     }
   if(UseRangeATRFilter)
     {
      if(RangeATRPeriod < 1)
         return FailInit("RangeATRPeriod must be >= 1 when UseRangeATRFilter is enabled.");
      if(RangeMaxATRMultiple <= 0.0)
         return FailInit("RangeMaxATRMultiple must be > 0 when UseRangeATRFilter is enabled.");
     }
   if(StraddleExpiryBars < 1)
      return FailInit("StraddleExpiryBars must be >= 1.");
   if(StraddleExpiryHours < 1)
      return FailInit("StraddleExpiryHours must be >= 1.");
   if(StraddleRearmDelayBars < 0)
      return FailInit("StraddleRearmDelayBars must be >= 0.");

   if(UseSessionFilter)
     {
      if(SessionStartHour < 0 || SessionStartHour > 24)
         return FailInit("SessionStartHour must be within [0,24].");
      if(SessionEndHour <= 0 || SessionEndHour > 24)
         return FailInit("SessionEndHour must be within (0,24].");
      if(SessionStartHour >= SessionEndHour)
         return FailInit("SessionStartHour must be smaller than SessionEndHour.");
     }
   return true;
  }

//+------------------------------------------------------------------+
//|  Indicator helpers                                                |
//+------------------------------------------------------------------+
//--- CompletedATR : reads the ATR of the last COMPLETED bar.
//--- handle : indicator handle. Returns: ATR value, 0.0 on failure.
double CompletedATR(const int handle)
  {
   if(handle == INVALID_HANDLE)
      return 0.0;
   double buffer[1];
   if(CopyBuffer(handle, 0, 1, 1, buffer) != 1)
      return 0.0;
   return buffer[0];
  }

//+------------------------------------------------------------------+
//|  Live state reconstruction                                        |
//+------------------------------------------------------------------+
//--- SortGridByOpenTime : insertion sort of g_grid by open time ascending.
//--- Returns: void.
void SortGridByOpenTime()
  {
   int total = ArraySize(g_grid);
   for(int i = 1; i < total; i++)
     {
      GridLevel key = g_grid[i];
      int j = i - 1;
      while(j >= 0 && g_grid[j].openTime > key.openTime)
        {
         g_grid[j + 1] = g_grid[j];
         j--;
        }
      g_grid[j + 1] = key;
     }
  }

//--- ParseLevelComment : extracts the level index from "MG_Grid_Level{n}".
//--- comment : position comment.  fallback : index used when the comment is not recognized.
//--- Returns: parsed level index or fallback.
int ParseLevelComment(const string comment, const int fallback)
  {
   if(StringFind(comment, LEVEL_COMMENT_PREFIX) != 0)
      return fallback;
   string digits = StringSubstr(comment, StringLen(LEVEL_COMMENT_PREFIX));
   if(StringLen(digits) == 0)
      return fallback;
   for(int i = 0; i < StringLen(digits); i++)
     {
      int ch = StringGetCharacter(digits, i);
      if(ch < '0' || ch > '9')
         return fallback;
     }
   int value = (int)StringToInteger(digits);
   if(value <= 0)
      return fallback;
   return value;
  }

//--- AssignLevels : fills g_grid[].level using comments with an open-time fallback.
//--- Returns: void.
void AssignLevels()
  {
   int total = ArraySize(g_grid);
   for(int i = 0; i < total; i++)
     {
      int fallback = i + 1;   // sorted order == chronological level order
      if(!PositionSelectByTicket(g_grid[i].ticket))
        {
         g_grid[i].level = fallback;
         continue;
        }
      string comment = PositionGetString(POSITION_COMMENT);
      g_grid[i].level = ParseLevelComment(comment, fallback);
     }
  }

//--- GridHasBothSides : true when the basket holds BUY and SELL positions.
//--- Returns: bool.
bool GridHasBothSides()
  {
   int total = ArraySize(g_grid);
   bool hasBuy = false, hasSell = false;
   for(int i = 0; i < total; i++)
     {
      if(g_grid[i].side == POSITION_TYPE_BUY)
         hasBuy = true;
      else
         hasSell = true;
     }
   return hasBuy && hasSell;
  }

//--- SumLots : total volume of all tracked positions.
//--- Returns: summed lots.
double SumLots()
  {
   int total = ArraySize(g_grid);
   double lots = 0.0;
   for(int i = 0; i < total; i++)
      lots += g_grid[i].lots;
   return lots;
  }

//--- HighestLevelIndex : index of the position carrying the highest level number.
//--- Returns: array index, or 0 for an empty grid.
int HighestLevelIndex()
  {
   int total = ArraySize(g_grid);
   if(total <= 0)
      return 0;
   int best = 0;
   for(int i = 1; i < total; i++)
     {
      if(g_grid[i].level >= g_grid[best].level)
         best = i;
     }
   return best;
  }

//--- RebuildGrid : rebuilds g_grid from live terminal positions (fresh every tick).
//--- Only positions on this symbol with magic 892174 are collected.
//--- Also refreshes the dirty flag and resets the ATR freeze while flat.
//--- Returns: void.
void RebuildGrid()
  {
   ArrayResize(g_grid, 0);
   int total = (int)PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)EA_MAGIC)
         continue;
      int size = ArraySize(g_grid);
      ArrayResize(g_grid, size + 1);
      g_grid[size].ticket   = ticket;
      g_grid[size].price    = PositionGetDouble(POSITION_PRICE_OPEN);
      g_grid[size].lots     = PositionGetDouble(POSITION_VOLUME);
      g_grid[size].openTime = (datetime)PositionGetInteger(POSITION_TIME);
      g_grid[size].side     = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      g_grid[size].level    = 0;
     }
   SortGridByOpenTime();
   AssignLevels();
   g_gridDirty = (ArraySize(g_grid) > 1) && GridHasBothSides();
   if(ArraySize(g_grid) == 0 && g_gridATRSet)
     {
      g_gridATRSet = false;
      g_gridATR = 0.0;
     }
  }

//--- OrderExists : true when the ticket is a live pending order of this EA/symbol.
//--- ticket : order ticket. Returns: bool.
bool OrderExists(const ulong ticket)
  {
   if(ticket == 0)
      return false;
   if(!OrderSelect(ticket))
      return false;
   if(OrderGetString(ORDER_SYMBOL) != _Symbol)
      return false;
   if(OrderGetInteger(ORDER_MAGIC) != (long)EA_MAGIC)
      return false;
   if(OrderGetInteger(ORDER_STATE) != ORDER_STATE_PLACED)
      return false;
   return true;
  }

//--- CountPendingMagic : number of live pending orders (BuyStop/SellStop) of this EA.
//--- Returns: count.
int CountPendingMagic()
  {
   int count = 0;
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)EA_MAGIC)
         continue;
      long type = OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;
      if(OrderGetInteger(ORDER_STATE) != ORDER_STATE_PLACED)
         continue;
      count++;
     }
   return count;
  }

//--- OrderPrice : price of a pending order.
//--- ticket : order ticket. Returns: price, 0.0 when the order cannot be selected.
double OrderPrice(const ulong ticket)
  {
   if(ticket == 0 || !OrderSelect(ticket))
      return 0.0;
   return OrderGetDouble(ORDER_PRICE_OPEN);
  }

//--- DeriveState : builds the state machine state from live terminal data only.
//--- Returns: current state.
ENUM_STRADDLE_STATE DeriveState()
  {
   if(ArraySize(g_grid) > 0)
      return STATE_IN_GRID;
   if(CountPendingMagic() > 0)
      return STATE_ARMED;
   return STATE_IDLE;
  }

//+------------------------------------------------------------------+
//|  Execution helpers                                                |
//+------------------------------------------------------------------+
//--- IsOkRetcode : true for accepted retcodes (pending placed, fill done).
//--- retcode : trade server retcode. Returns: bool.
bool IsOkRetcode(const uint retcode)
  {
   return (retcode == (uint)TRADE_RETCODE_PLACED ||
           retcode == (uint)TRADE_RETCODE_DONE ||
           retcode == (uint)TRADE_RETCODE_DONE_PARTIAL);
  }

//--- CancelPendingTicket : deletes one pending order, bounded retries.
//--- ticket : order ticket. Returns: true when the order is gone afterwards.
bool CancelPendingTicket(const ulong ticket)
  {
   if(ticket == 0)
      return true;
   if(!OrderExists(ticket))
      return true;
   for(int attempt = 1; attempt <= MaxRetries; attempt++)
     {
      if(g_trade.OrderDelete(ticket) && IsOkRetcode(g_trade.ResultRetcode()))
        {
         LogInfo(StringFormat("[GM] Pending %s cancelled.", TicketStr(ticket)));
         return true;
        }
      LogInfo(StringFormat("[GM] Cancel attempt %d/%d failed for %s (retcode=%u).",
                           attempt, MaxRetries, TicketStr(ticket), g_trade.ResultRetcode()));
      if(attempt < MaxRetries)
         Sleep((int)OrderRetryDelayMs);
     }
   LogError(StringFormat("[GM] Could not cancel pending %s after %d attempts (retcode=%u).",
                         TicketStr(ticket), MaxRetries, g_trade.ResultRetcode()));
   return false;
  }

//--- CancelAllPending : deletes every pending order of this EA/symbol.
//--- Returns: number of cancelled orders.
int CancelAllPending()
  {
   int cancelled = 0;
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)EA_MAGIC)
         continue;
      long type = OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;
      if(CancelPendingTicket(ticket))
         cancelled++;
     }
   return cancelled;
  }

//--- ClosePositionTicket : closes one position in full, bounded retries.
//--- ticket : position ticket. Returns: true when closed (or already gone).
bool ClosePositionTicket(const ulong ticket)
  {
   if(ticket == 0)
      return true;
   if(!PositionSelectByTicket(ticket))
      return true;
   for(int attempt = 1; attempt <= MaxRetries; attempt++)
     {
      if(g_trade.PositionClose(ticket) && IsOkRetcode(g_trade.ResultRetcode()))
        {
         LogInfo(StringFormat("[GM] Position %s closed (retcode=%u).", TicketStr(ticket), g_trade.ResultRetcode()));
         return true;
        }
      LogInfo(StringFormat("[GM] Close attempt %d/%d failed for %s (retcode=%u).",
                           attempt, MaxRetries, TicketStr(ticket), g_trade.ResultRetcode()));
      if(attempt < MaxRetries)
         Sleep((int)OrderRetryDelayMs);
     }
   LogError(StringFormat("[GM] Could not close position %s after %d attempts (retcode=%u).",
                         TicketStr(ticket), MaxRetries, g_trade.ResultRetcode()));
   return false;
  }

//--- CloseAllPositions : closes the basket oldest-first.
//--- Returns: number of closed positions.
int CloseAllPositions()
  {
   int closed = 0;
   int total = ArraySize(g_grid);
   for(int i = 0; i < total; i++)
     {
      if(ClosePositionTicket(g_grid[i].ticket))
         closed++;
     }
   return closed;
  }

//--- NormalizeLot : rounds a volume down to the broker step and enforces caps.
//--- raw : requested volume.  capLimit : extra ceiling (e.g. remaining lot budget).
//--- Returns: normalized volume, or 0.0 when the request cannot be honored.
double NormalizeLot(const double raw, const double capLimit)
  {
   double volMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volStep <= 0.0 || volMin <= 0.0 || volMax <= 0.0)
      return 0.0;
   double cap = MathMin(MaxLotSize, volMax);
   if(capLimit > 0.0)
      cap = MathMin(cap, capLimit);
   if(cap < volMin)
      return 0.0;                       // no room for even the smallest lot
   double lot = MathFloor(raw / volStep + LOT_TOLERANCE) * volStep;   // round DOWN to step
   if(lot < volMin)
      lot = volMin;
   if(lot > cap)
      lot = cap;
   lot = NormalizeDouble(lot, LOT_DECIMALS);
   if(lot < volMin || lot > volMax)
      return 0.0;
   return lot;
  }

//--- SendGridLevelWithRetry : opens a market grid level, bounded retries.
//--- side : BUY or SELL.  lots : normalized volume.  level : target level number.
//--- Returns: order ticket, 0 on failure.
ulong SendGridLevelWithRetry(const ENUM_POSITION_TYPE side, const double lots, const int level)
  {
   string comment = StringFormat("%s%d", LEVEL_COMMENT_PREFIX, level);
   for(int attempt = 1; attempt <= MaxRetries; attempt++)
     {
      bool sent = false;
      if(side == POSITION_TYPE_BUY)
         sent = g_trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, comment);
      else
         sent = g_trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, comment);
      if(sent && IsOkRetcode(g_trade.ResultRetcode()))
        {
         ulong ticket = g_trade.ResultOrder();
         LogInfo(StringFormat("[GM] Grid level %d %s sent at %s, lots=%.2f, ticket=%s (attempt %d/%d).",
                              level, PositionSideStr(side), PriceStr(g_trade.ResultPrice()),
                              lots, TicketStr(ticket), attempt, MaxRetries));
         return ticket;
        }
      LogInfo(StringFormat("[GM] Order send failed (attempt %d/%d): retcode=%u %s.",
                           attempt, MaxRetries, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      if(attempt < MaxRetries)
         Sleep((int)OrderRetryDelayMs);
     }
   return 0;
  }

//--- SendStraddleWithRetry : places one straddle pending order, bounded retries.
//--- type : ORDER_TYPE_BUY_STOP or ORDER_TYPE_SELL_STOP.  price : normalized price.  lots : volume.
//--- Returns: order ticket, 0 on failure.
ulong SendStraddleWithRetry(const ENUM_ORDER_TYPE type, const double price, const double lots)
  {
   string comment = (type == ORDER_TYPE_BUY_STOP) ? BUYSTOP_COMMENT : SELLSTOP_COMMENT;
   for(int attempt = 1; attempt <= MaxRetries; attempt++)
     {
      double p = NormalizeDouble(price, _Digits);
      bool sent = false;
      if(type == ORDER_TYPE_BUY_STOP)
         sent = g_trade.BuyStop(lots, p, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, (datetime)0, comment);
      else
         sent = g_trade.SellStop(lots, p, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, (datetime)0, comment);
      if(sent && IsOkRetcode(g_trade.ResultRetcode()))
        {
         ulong ticket = g_trade.ResultOrder();
         LogInfo(StringFormat("[GM] %s placed at %s, lots=%.2f, ticket=%s (attempt %d/%d).",
                              comment, PriceStr(p), lots, TicketStr(ticket), attempt, MaxRetries));
         return ticket;
        }
      LogInfo(StringFormat("[GM] %s rejected (attempt %d/%d): retcode=%u %s.",
                           comment, attempt, MaxRetries, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      if(attempt < MaxRetries)
         Sleep((int)OrderRetryDelayMs);
     }
   return 0;
  }

//+------------------------------------------------------------------+
//|  Filters                                                          |
//+------------------------------------------------------------------+
//--- SpreadOK : true when the current spread is within MaxSpreadPoints.
//--- Returns: bool.
bool SpreadOK()
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread <= 0)                       // spread unknown: do not block trading
      return true;
   return spread <= (long)MaxSpreadPoints;
  }

//--- SessionHour : current hour in broker server time.
//--- Returns: hour 0..23, or -1 when the server clock cannot be read.
int SessionHour()
  {
   MqlDateTime dt;
   if(!TimeToStruct(ServerTimeNow(), dt))
      return -1;
   return dt.hour;
  }

//--- InSession : true when the current server hour is inside [SessionStartHour, SessionEndHour).
//--- Returns: bool.
bool InSession()
  {
   if(!UseSessionFilter)
      return true;
   int hour = SessionHour();
   if(hour < 0)
      return false;
   return (hour >= SessionStartHour && hour < SessionEndHour);
  }

//--- InNewsBlackout : true when "now" falls inside a configured blackout window.
//--- Windows are "YYYY.MM.DD HH:MM-HH:MM" separated by ';'. When the end time is
//--- not after the start time the window is treated as spilling into the next day.
//--- Times are compared against TimeCurrent(), the same basis used by StringToTime.
//--- Returns: bool.
bool InNewsBlackout()
  {
   if(!UseNewsFilter)
      return false;
   if(StringLen(NewsBlackoutWindows) == 0)
      return false;
   datetime now = TimeCurrent();
   string items[];
   int count = StringSplit(NewsBlackoutWindows, ';', items);
   if(count <= 0)
      return false;
   for(int i = 0; i < count; i++)
     {
      string window = items[i];
      StringTrimLeft(window);
      StringTrimRight(window);
      if(StringLen(window) == 0)
         continue;
      int spacePos = StringFind(window, " ");
      if(spacePos <= 0)
         continue;
      string datePart = StringSubstr(window, 0, spacePos);
      string timePart = StringSubstr(window, spacePos + 1);
      int dashPos = StringFind(timePart, "-");
      if(dashPos <= 0)
         continue;
      datetime start = StringToTime(datePart + " " + StringSubstr(timePart, 0, dashPos));
      datetime end   = StringToTime(datePart + " " + StringSubstr(timePart, dashPos + 1));
      if(start == 0 || end == 0)
         continue;
      if(end <= start)
         end += SECONDS_PER_DAY;
      if(now >= start && now <= end)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  Safety layer                                                     |
//+------------------------------------------------------------------+
//--- CheckNewDayRoll : resets the daily equity baseline and clears halts on broker day change.
//--- Returns: void.
void CheckNewDayRoll()
  {
   int day = ServerDayIndex();
   if(day == g_serverDayIndex)
      return;
   g_serverDayIndex = day;
   g_startOfDayEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   bool wasHalted = g_halted;
   g_halted = false;
   g_haltReason = "";
   if(wasHalted)
      LogInfo(StringFormat("[GM] New server day: halt cleared, startOfDayEquity reset to %.2f.", g_startOfDayEquity));
   else
      LogInfo(StringFormat("[GM] New server day: startOfDayEquity reset to %.2f.", g_startOfDayEquity));
  }

//--- TriggerHalt : closes everything, cancels pendings and latches the halt flag.
//--- reason : human readable trigger description. Returns: void.
void TriggerHalt(const string reason)
  {
   g_halted = true;
   g_haltReason = reason;
   int closed = CloseAllPositions();
   int cancelled = CancelAllPending();
   LogError(StringFormat("HALT TRIGGERED: %s. Positions closed: %d, pendings cancelled: %d. "
                         "Trading resumes after the next broker day roll.",
                         reason, closed, cancelled));
  }

//--- SafetyCheck : equity stop and daily loss evaluation (both vs start-of-day equity).
//--- Returns: true when a halt was triggered on this call.
bool SafetyCheck()
  {
   if(g_halted)
      return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double equityFloor = g_startOfDayEquity * (1.0 - EquityStopPercent / PERCENT_UNIT);
   double dailyFloor   = g_startOfDayEquity * (1.0 - DailyLossPercent / PERCENT_UNIT);
   if(equity <= equityFloor)
     {
      TriggerHalt(StringFormat("Equity stop: equity %.2f <= %.2f (%.1f%% of %.2f)",
                               equity, equityFloor, EquityStopPercent, g_startOfDayEquity));
      return true;
     }
   if(equity <= dailyFloor)
     {
      TriggerHalt(StringFormat("Daily loss: equity %.2f <= %.2f (%.1f%% of %.2f)",
                               equity, dailyFloor, DailyLossPercent, g_startOfDayEquity));
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  Grid spacing / lot maths                                         |
//+------------------------------------------------------------------+
//--- CurrentStepSize : grid step for the next level after level lastLevel.
//--- lastLevel : number of the current deepest level. Returns: price distance.
double CurrentStepSize(const int lastLevel)
  {
   int exponent = MathMax(1, lastLevel) - 1;
   switch(SpacingMode)
     {
      case SPACING_FIXED:
         return GridStepPoints * _Point;
      case SPACING_ATR:
         {
         double atr = g_gridATRSet ? g_gridATR : CompletedATR(g_handleGridATR);
         return atr * ATRMultiplier;
        }
      case SPACING_MULTIPLICATIVE:
         return SpacingBasePoints * _Point * MathPow(SpacingMultiplier, (double)exponent);
      default:
         return GridStepPoints * _Point;
     }
  }

//--- NextTriggerPrice : price at which the next level would be added (logging helper).
//--- referencePrice : price of the deepest level.  step : grid step.
//--- Returns: normalized trigger price.
double NextTriggerPrice(const double referencePrice, const double step)
  {
   if(ArraySize(g_grid) == 0)
      return NormalizeDouble(referencePrice, _Digits);
   if(g_grid[0].side == POSITION_TYPE_BUY)
      return NormalizeDouble(referencePrice - step, _Digits);
   return NormalizeDouble(referencePrice + step, _Digits);
  }

//--- FreezeGridATR : snapshots the grid ATR at level-1 fill time (once per grid).
//--- Returns: void.
void FreezeGridATR()
  {
   if(g_gridATRSet)
      return;
   g_gridATRSet = true;
   if(SpacingMode == SPACING_ATR)
     {
      g_gridATR = CompletedATR(g_handleGridATR);
      LogInfo(StringFormat("[GM] Grid ATR snapshot frozen at %s.", PriceStr(g_gridATR)));
     }
  }

//+------------------------------------------------------------------+
//|  STATE_IN_GRID                                                    |
//+------------------------------------------------------------------+
//--- HandleStraddleTrigger : post-fill bookkeeping when entering the grid from ARMED.
//--- Cancels the surviving leg and resolves the rare both-legs-filled gap case.
//--- Returns: void.
void HandleStraddleTrigger()
  {
   bool buyGone  = (g_buyStopTicket != 0)  && !OrderExists(g_buyStopTicket);
   bool sellGone = (g_sellStopTicket != 0) && !OrderExists(g_sellStopTicket);
   string side = "UNKNOWN";
   if(ArraySize(g_grid) > 0)
      side = PositionSideStr(g_grid[0].side);

   // Gap-through edge case: both pendings filled -> one position per side.
   if(buyGone && sellGone && GridHasBothSides())
     {
      int buyIdx = -1, sellIdx = -1;
      for(int i = 0; i < ArraySize(g_grid); i++)
        {
         if(g_grid[i].side == POSITION_TYPE_BUY && buyIdx < 0)
            buyIdx = i;
         else
            if(g_grid[i].side == POSITION_TYPE_SELL && sellIdx < 0)
               sellIdx = i;
        }
      if(buyIdx >= 0 && sellIdx >= 0)
        {
         double buyDist = MathAbs(g_grid[buyIdx].price - g_armMid);
         double sellDist = MathAbs(g_grid[sellIdx].price - g_armMid);
         int loser = (buyDist <= sellDist) ? buyIdx : sellIdx;
         LogError(StringFormat("Both straddle legs filled (gap through the range). Keeping the larger "
                               "breakout leg %s and closing the weaker position %s.",
                               PositionSideStr((loser == buyIdx) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY),
                               TicketStr(g_grid[loser].ticket)));
         ClosePositionTicket(g_grid[loser].ticket);
        }
     }

   if(ArraySize(g_grid) > 0)
      side = PositionSideStr(g_grid[0].side);
   LogInfo(StringFormat("[GM] Straddle triggered on %s side. Opposing pending cancelled.", side));
  }

//--- ManageGridAdds : adds the next grid level when price moved against the grid.
//--- Returns: void.
void ManageGridAdds()
  {
   int count = ArraySize(g_grid);
   if(count <= 0)
      return;
   if(g_gridDirty)
     {
      LogSkip("[GM] Grid dirty: positions on both sides, managing exits only (no new levels).");
      return;
     }
   if(g_halted)
     {
      LogSkip("[GM] Grid add skipped: EA is halted (" + g_haltReason + ").");
      return;
     }

   int lastIdx = HighestLevelIndex();
   int levelN = g_grid[lastIdx].level;
   double lastPrice = g_grid[lastIdx].price;
   ENUM_POSITION_TYPE direction = g_grid[0].side;    // level 1 fixes the side of the whole series
   double step = CurrentStepSize(levelN);
   if(!(step > 0.0))
     {
      LogSkip(StringFormat("[GM] Grid add skipped: invalid step size (%.8f).", step));
      return;
     }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double against = (direction == POSITION_TYPE_BUY) ? (lastPrice - bid) : (ask - lastPrice);
   if(against < step)                                // no trigger yet: stay silent
      return;

   if(count >= MaxGridLevels)
     {
      LogSkip(StringFormat("[GM] Grid add skipped: MaxGridLevels (%d) reached.", MaxGridLevels));
      return;
     }
   if(!SpreadOK())
     {
      LogSkip(StringFormat("[GM] Grid add skipped: spread %d > MaxSpreadPoints %d.",
                           (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), MaxSpreadPoints));
      return;
     }

   double totalLots = SumLots();
   double rawLot = BaseLot * MathPow(LotMultiplier, (double)levelN);
   double lot = NormalizeLot(rawLot, MaxTotalLots - totalLots);   // cap to free headroom
   if(lot <= 0.0)
     {
      LogSkip(StringFormat("[GM] Grid add skipped: MaxTotalLots headroom (%.2f) below broker volume minimum.",
                           MaxTotalLots - totalLots));
      return;
     }
   if(totalLots + lot > MaxTotalLots + LOT_TOLERANCE)
     {
      LogSkip(StringFormat("[GM] Grid add skipped: MaxTotalLots %.2f would be exceeded (current %.2f).",
                           MaxTotalLots, totalLots));
      return;
     }

   int nextLevel = levelN + 1;
   ulong ticket = SendGridLevelWithRetry(direction, lot, nextLevel);
   if(ticket == 0)
      LogError(StringFormat("[GM] Grid level %d could not be opened after %d attempts.", nextLevel, MaxRetries));
   else
      LogInfo(StringFormat("[GM] Grid level %d/%d added on %s: lots=%.2f, total lots=%.2f.",
                           nextLevel, MaxGridLevels, PositionSideStr(direction), lot, totalLots + lot));
  }

//--- OldestProfitableIndex : index of the oldest position currently in profit.
//--- Returns: array index, or -1 when none is profitable.
int OldestProfitableIndex()
  {
   int total = ArraySize(g_grid);
   for(int i = 0; i < total; i++)
     {
      if(!PositionSelectByTicket(g_grid[i].ticket))
         continue;
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pl > 0.0)
         return i;
     }
   return -1;
  }

//--- ComputeBasketTPPrice : converts the code-driven basket money target into a
//--- server-side TP price anchored on the volume-weighted average entry.
//--- outPrice : receives the normalized TP price (0.0 on failure).
//--- Returns: false when no single price can express the basket (empty/dirty/mixed
//--- side grid), when the tick value conversion is unusable, when the derived price
//--- is non-positive, or when the broker stop/freeze distance would reject the TP.
//--- The TP is NEVER moved closer to the market to satisfy the stop-level guard:
//--- returning false lets the next tick retry instead of weakening the safety net.
bool ComputeBasketTPPrice(double &outPrice)
  {
   outPrice = 0.0;
   int count = ArraySize(g_grid);
   if(count <= 0)
      return false;
   if(g_gridDirty)
      return false;

   ENUM_POSITION_TYPE side = g_grid[0].side;
   double totalLots = 0.0;
   double weightedSum = 0.0;
   for(int i = 0; i < count; i++)
     {
      if(g_grid[i].side != side)
         return false;                 // mixed sides: no single price hits the money target
      totalLots += g_grid[i].lots;
      weightedSum += g_grid[i].price * g_grid[i].lots;
     }
   if(!(totalLots > 0.0))
      return false;

   double target = totalLots * MoneyPerLotTP;
   if(UseTPDecay)
      target *= MathPow(TPDecayFactor, (double)count - 1.0);
   target *= BasketTPSafetyFactor;      // strictly behind the code-driven exit
   if(!(target > 0.0))
      return false;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return false;
   double moneyPerPointPerLot = (tickValue / tickSize) * _Point;
   if(!(moneyPerPointPerLot > 0.0))
      return false;

   double avgEntry = weightedSum / totalLots;
   // target / (lots * moneyPerPointPerLot) is expressed in POINTS; convert to price units.
   double priceDistance = target / (totalLots * moneyPerPointPerLot) * _Point;
   double tp = (side == POSITION_TYPE_BUY) ? (avgEntry + priceDistance)
                                           : (avgEntry - priceDistance);
   tp = NormalizeDouble(tp, _Digits);
   if(!(tp > 0.0))
      return false;

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = (double)MathMax(stopsLevel, freezeLevel) * _Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(side == POSITION_TYPE_BUY  && (tp - bid) < minDist)
      return false;
   if(side == POSITION_TYPE_SELL && (ask - tp) < minDist)
      return false;

   outPrice = tp;
   return true;
  }

//--- ApplyBasketTP : mirrors the computed server-side TP onto every basket order.
//--- Existing SLs are preserved (always 0.0 in this EA, but never rewritten blindly).
//--- Idempotent: orders whose TP is already within half a point are left untouched,
//--- so a no-op tick issues no modify calls. Failures are logged, not retried here.
//--- Returns: number of orders whose TP is correct afterwards (modified or matching).
int ApplyBasketTP()
  {
   double tp = 0.0;
   if(!ComputeBasketTPPrice(tp))
      return 0;

   int count = ArraySize(g_grid);
   int correct = 0;
   int modified = 0;
   for(int i = 0; i < count; i++)
     {
      ulong ticket = g_grid[i].ticket;
      if(!PositionSelectByTicket(ticket))
         continue;
      double currentTP = PositionGetDouble(POSITION_TP);
      if(MathAbs(currentTP - tp) <= 0.5 * _Point)
        {
         correct++;
         continue;
        }
      double currentSL = PositionGetDouble(POSITION_SL);
      if(g_trade.PositionModify(ticket, currentSL, tp) && IsOkRetcode(g_trade.ResultRetcode()))
        {
         correct++;
         modified++;
        }
      else
         LogInfo(StringFormat("[GM] Server-side TP modify failed for %s (retcode=%u %s).",
                              TicketStr(ticket), g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
     }
   if(modified > 0)
      LogInfo(StringFormat("[GM] Server-side basket TP %s applied to %d order(s).", PriceStr(tp), modified));
   return correct;
  }

//--- ClearBasketTP : strips server-side TPs from the basket (best effort, silent failures).
//--- Used when the grid turns dirty or a partial close changed the basket composition,
//--- so stale single prices can never fire on a basket that has no such break-even.
//--- Returns: number of orders whose TP was cleared.
int ClearBasketTP()
  {
   int cleared = 0;
   int count = ArraySize(g_grid);
   for(int i = 0; i < count; i++)
     {
      ulong ticket = g_grid[i].ticket;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetDouble(POSITION_TP) == 0.0)
         continue;
      double currentSL = PositionGetDouble(POSITION_SL);
      if(g_trade.PositionModify(ticket, currentSL, 0.0) && IsOkRetcode(g_trade.ResultRetcode()))
         cleared++;
     }
   return cleared;
  }

//--- ManageExits : dynamic basket TP and optional partial close.
//--- NOTE: floating PL = POSITION_PROFIT + POSITION_SWAP. Commission is deliberately
//--- excluded (most brokers report it separately); adjust MoneyPerLotTP if needed.
//--- Returns: void.
void ManageExits()
  {
   int count = ArraySize(g_grid);
   if(count <= 0)
      return;

   double totalLots = 0.0;
   double floatingPL = 0.0;
   for(int i = 0; i < count; i++)
     {
      if(!PositionSelectByTicket(g_grid[i].ticket))
         continue;
      totalLots += g_grid[i].lots;
      floatingPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   if(!(totalLots > 0.0))
      return;

   // Basket TP is a money target and is recomputed on every tick.
   double target = totalLots * MoneyPerLotTP;
   if(UseTPDecay)
      target *= MathPow(TPDecayFactor, (double)count - 1.0);
   if(!(target > 0.0))
      return;

   if(UsePartialClose && floatingPL >= target * PartialCloseRatio)
     {
      int idx = OldestProfitableIndex();
      if(idx >= 0)
        {
         ulong ticket = g_grid[idx].ticket;
         LogInfo(StringFormat("[GM] Partial close: PL %.2f reached %.1f%% of target %.2f, closing oldest profitable position %s.",
                              floatingPL, PartialCloseRatio * PERCENT_UNIT, target, TicketStr(ticket)));
         if(ClosePositionTicket(ticket))
           {
            g_lastCloseBar = CurrentBarTime();
            if(UseServerSideBasketTP)
              {
               RebuildGrid();       // remaining orders must mirror the NEW basket composition
               ApplyBasketTP();
              }
            return;               // basket continues with the remaining levels
           }
        }
     }

   if(floatingPL >= target)
     {
      int closed = CloseAllPositions();
      LogInfo(StringFormat("[GM] Basket closed. Levels: %d, Lots: %.2f, PL: %.2f (target %.2f, closed %d positions).",
                           count, totalLots, floatingPL, target, closed));
      g_lastCloseBar = CurrentBarTime();   // re-arm gating
     }
  }

//--- ManageInGrid : grid management while a basket is open.
//--- Returns: void.
void ManageInGrid()
  {
   CancelAllPending();          // safety: no straddle leg may survive a fill

   if(UseServerSideBasketTP)
     {
      if(g_gridDirty)
         ClearBasketTP();
      else
         ApplyBasketTP();
     }

   ManageGridAdds();
   ManageExits();
  }

//+------------------------------------------------------------------+
//|  STATE_ARMED                                                      |
//+------------------------------------------------------------------+
//--- ArmedExpired : true when the armed straddle exceeded its bar or hour budget.
//--- Returns: bool.
bool ArmedExpired()
  {
   if(g_armTime <= 0)
      return true;
   if(BarsSinceTime(g_armTime) >= StraddleExpiryBars)
      return true;
   if(HoursSince(g_armTime) >= (double)StraddleExpiryHours)
      return true;
   return false;
  }

//--- RefreshArmedTickets : re-reads the live BuyStop/SellStop tickets of the armed straddle.
//--- Returns: void.
void RefreshArmedTickets()
  {
   g_buyStopTicket = 0;
   g_sellStopTicket = 0;
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderExists(ticket))
         continue;
      long type = OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP)
         g_buyStopTicket = ticket;
      else
         if(type == ORDER_TYPE_SELL_STOP)
            g_sellStopTicket = ticket;
     }
  }

//--- ManageArmed : supervision of the pending straddle (expiry, one-legged states).
//--- Returns: void.
void ManageArmed()
  {
   if(g_halted)
     {
      int cancelled = CancelAllPending();
      LogInfo(StringFormat("[GM] Straddle cancelled: EA halted (%s), %d pending(s) removed.", g_haltReason, cancelled));
      return;
     }
   if(ArmedExpired())
     {
      int cancelled = CancelAllPending();
      LogInfo(StringFormat("[GM] Straddle expired after %d bars / %.2f h (armed %s), %d pending(s) cancelled.",
                           BarsSinceTime(g_armTime), HoursSince(g_armTime),
                           TimeToString(g_armTime, TIME_DATE | TIME_MINUTES), cancelled));
      g_lastCloseBar = CurrentBarTime();
      return;
     }
   if(CountPendingMagic() < 2)
     {
      LogInfo("[GM] WARNING: straddle lost a leg (pending removed externally). "
              "Cancelling the survivor and returning to IDLE.");
      CancelAllPending();
      g_lastCloseBar = CurrentBarTime();
      return;
     }
   RefreshArmedTickets();
  }

//+------------------------------------------------------------------+
//|  STATE_IDLE                                                       |
//+------------------------------------------------------------------+
//--- CopyRecentHighLow : highest high / lowest low of the last `count` COMPLETED bars.
//--- count : number of completed bars.  high : highest high.  low : lowest low.
//--- Returns: true when the data was copied completely.
bool CopyRecentHighLow(const int count, double &high, double &low)
  {
   if(count < 1)
      return false;
   double highs[];
   double lows[];
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, count, highs) != count)
      return false;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 1, count, lows) != count)
      return false;
   high = highs[0];
   low = lows[0];
   for(int i = 1; i < count; i++)
     {
      if(highs[i] > high)
         high = highs[i];
      if(lows[i] < low)
         low = lows[i];
     }
   return true;
  }

//--- ComputeStraddleRange : builds the straddle band and applies the ATR validity filter.
//--- rangeHigh : upper band.  rangeLow : lower band.  Returns: true when the range may be armed.
bool ComputeStraddleRange(double &rangeHigh, double &rangeLow)
  {
   double high = 0.0, low = 0.0;
   if(StraddleRangeMode == RANGE_CANDLES)
     {
      int lookback = MathMax(MIN_LOOKBACK_BARS, RangeLookbackCandles);
      if(!CopyRecentHighLow(lookback, high, low))
        {
         LogSkip("[GM] Range: not enough completed-bar history, waiting.");
         return false;
        }
     }
   else
     {
      int anchor = MathMax(MIN_LOOKBACK_BARS, RangePipAnchorCandles);
      double anchorHigh = 0.0, anchorLow = 0.0;
      if(!CopyRecentHighLow(anchor, anchorHigh, anchorLow))
        {
         LogSkip("[GM] Range: not enough completed-bar history, waiting.");
         return false;
        }
      double mid = (anchorHigh + anchorLow) / 2.0;
      double halfDistance = (RangeDistancePips * _Point * POINTS_PER_PIP) / 2.0;   // spec: 1 pip = 10 points
      high = mid + halfDistance;
      low = mid - halfDistance;
     }

   rangeHigh = NormalizeDouble(high, _Digits);
   rangeLow = NormalizeDouble(low, _Digits);
   if(rangeHigh <= rangeLow)
     {
      LogSkip("[GM] Range: rangeHigh <= rangeLow, skipping.");
      return false;
     }

   if(UseRangeATRFilter)
     {
      double atr = CompletedATR(g_handleRangeATR);
      if(atr <= 0.0)
        {
         LogSkip("[GM] Range: ATR readout unavailable, skipping.");
         return false;
        }
      if(rangeHigh - rangeLow > atr * RangeMaxATRMultiple)
        {
         LogSkip(StringFormat("[GM] Range too wide vs ATR, waiting: width %s > ATR %s x %.2f.",
                              PriceStr(rangeHigh - rangeLow), PriceStr(atr), RangeMaxATRMultiple));
         return false;
        }
      LogSkip(StringFormat("[GM] Range OK: high=%s low=%s width=%s ATR=%s (limit x%.2f).",
                           PriceStr(rangeHigh), PriceStr(rangeLow), PriceStr(rangeHigh - rangeLow),
                           PriceStr(atr), RangeMaxATRMultiple));
     }
   else
      LogSkip(StringFormat("[GM] Range OK: high=%s low=%s width=%s (ATR filter disabled).",
                           PriceStr(rangeHigh), PriceStr(rangeLow), PriceStr(rangeHigh - rangeLow)));
   return true;
  }

//--- ApplyStopLevels : pushes both stops outside the broker minimum stop distance.
//--- rangeHigh : upper band (in/out).  rangeLow : lower band (in/out).  Returns: true when usable.
bool ApplyStopLevels(double &rangeHigh, double &rangeLow)
  {
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDistance = ((double)MathMax(stopsLevel, freezeLevel) + (double)StopLevelBufferPoints) * _Point;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(rangeHigh < ask + minDistance)
     {
      rangeHigh = NormalizeDouble(ask + minDistance, _Digits);
      LogSkip(StringFormat("[GM] Stop-level compliance: BuyStop raised to %s (stops level %d, freeze level %d, buffer %d).",
                           PriceStr(rangeHigh), (int)stopsLevel, (int)freezeLevel, StopLevelBufferPoints));
     }
   if(rangeLow > bid - minDistance)
     {
      rangeLow = NormalizeDouble(bid - minDistance, _Digits);
      LogSkip(StringFormat("[GM] Stop-level compliance: SellStop lowered to %s (stops level %d, freeze level %d, buffer %d).",
                           PriceStr(rangeLow), (int)stopsLevel, (int)freezeLevel, StopLevelBufferPoints));
     }
   if(!(rangeHigh > rangeLow))
     {
      LogSkip("[GM] Stop-level compliance: band collapsed after adjustment, skipping.");
      return false;
     }
   return true;
  }

//--- ManageIdle : entry logic of STATE_IDLE (straddle arming).
//--- Returns: void.
void ManageIdle()
  {
   // A one-legged straddle cannot be operated: clean up before re-arming.
   if(CountPendingMagic() > 0)
     {
      LogInfo("[GM] IDLE: stray pending order(s) with our magic found, cancelling before re-arming.");
      CancelAllPending();
      g_lastCloseBar = CurrentBarTime();
      return;
     }
   if(g_halted)
     {
      LogSkip("[GM] IDLE: EA halted (" + g_haltReason + "), not arming.");
      return;
     }
   if(BarsSinceTime(g_lastCloseBar) < StraddleRearmDelayBars)
     {
      LogSkip(StringFormat("[GM] IDLE: re-arm delay active (%d bar(s) requested).", StraddleRearmDelayBars));
      return;
     }
   if(!InSession())
     {
      LogSkip(StringFormat("[GM] IDLE: outside session [%d,%d) server time, waiting.", SessionStartHour, SessionEndHour));
      return;
     }
   if(!SpreadOK())
     {
      LogSkip(StringFormat("[GM] IDLE: spread %d > MaxSpreadPoints %d, waiting.",
                           (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), MaxSpreadPoints));
      return;
     }
   if(InNewsBlackout())
     {
      LogSkip("[GM] IDLE: news blackout window active, waiting.");
      return;
     }

   double rangeHigh = 0.0, rangeLow = 0.0;
   if(!ComputeStraddleRange(rangeHigh, rangeLow))
      return;
   if(!ApplyStopLevels(rangeHigh, rangeLow))
      return;

   double lot = NormalizeLot(BaseLot, MaxTotalLots);
   if(lot <= 0.0)
     {
      LogError("[GM] IDLE: BaseLot cannot be normalized to a valid volume for this symbol.");
      return;
     }

   g_buyStopTicket = SendStraddleWithRetry(ORDER_TYPE_BUY_STOP, rangeHigh, lot);
   if(g_buyStopTicket == 0)
     {
      LogError("[GM] Arming failed: BuyStop not placed.");
      return;
     }
   g_sellStopTicket = SendStraddleWithRetry(ORDER_TYPE_SELL_STOP, rangeLow, lot);
   if(g_sellStopTicket == 0)
     {
      LogError("[GM] Arming failed: SellStop not placed, cancelling the BuyStop.");
      CancelPendingTicket(g_buyStopTicket);
      g_buyStopTicket = 0;
      return;
     }

   g_armTime = TimeCurrent();
   g_armMid = NormalizeDouble((rangeHigh + rangeLow) / 2.0, _Digits);
   LogInfo(StringFormat("[GM] Straddle armed: BuyStop %s / SellStop %s / mid %s / lot %.2f / expiry %d bars or %d h.",
                        PriceStr(rangeHigh), PriceStr(rangeLow), PriceStr(g_armMid), lot,
                        StraddleExpiryBars, StraddleExpiryHours));
   LogTransition(STATE_IDLE, STATE_ARMED);
   g_state = STATE_ARMED;
  }

//+------------------------------------------------------------------+
//|  Recovery                                                         |
//+------------------------------------------------------------------+
//--- RecoverState : rebuilds the state machine from live terminal data at init.
//--- Positions win over pendings; a one-legged or same-sided straddle is cancelled.
//--- Returns: void.
void RecoverState()
  {
   RebuildGrid();
   int positions = ArraySize(g_grid);
   int pendings = CountPendingMagic();
   g_buyStopTicket = 0;
   g_sellStopTicket = 0;

   if(positions > 0)
     {
      if(g_gridDirty)
         LogError("Recovery: positions found on BOTH sides with magic 892174. Grid is dirty: "
                  "managing exits only, no new levels until the basket is flat.");
      int cancelled = CancelAllPending();
      if(SpacingMode == SPACING_ATR)
        {
         g_gridATR = CompletedATR(g_handleGridATR);
         g_gridATRSet = (g_gridATR > 0.0);
         LogInfo(StringFormat("[GM] Recovery: ATR step reconstructed from live ATR %s "
                              "(fill-time value is not recoverable after a restart).", PriceStr(g_gridATR)));
        }
      int lastIdx = HighestLevelIndex();
      int levelN = g_grid[lastIdx].level;
      double step = CurrentStepSize(levelN);
      LogInfo(StringFormat("[GM] Recovered grid with %d levels, total lots %.2f, next level at price %s "
                           "(%d stray pending(s) cancelled).",
                           positions, SumLots(),
                           PriceStr(NextTriggerPrice(g_grid[lastIdx].price, step)), cancelled));
      LogTransition(g_state, STATE_IN_GRID);
      g_state = STATE_IN_GRID;
      return;
     }

   if(pendings > 0)
     {
      if(pendings != 2)
        {
         LogError(StringFormat("[GM] Recovery: found %d pending order(s) instead of a complete straddle. "
                               "Cancelling them.", pendings));
         CancelAllPending();
         LogTransition(g_state, STATE_IDLE);
         g_state = STATE_IDLE;
         return;
        }
      RefreshArmedTickets();
      if(g_buyStopTicket == 0 || g_sellStopTicket == 0)
        {
         LogError("[GM] Recovery: pending orders are not on opposite sides. Cancelling them.");
         CancelAllPending();
         g_buyStopTicket = 0;
         g_sellStopTicket = 0;
         LogTransition(g_state, STATE_IDLE);
         g_state = STATE_IDLE;
         return;
        }
      datetime setup = 0;
      if(OrderExists(g_buyStopTicket))
         setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(setup <= 0 && OrderExists(g_sellStopTicket))
         setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      g_armTime = (setup > 0) ? setup : TimeCurrent();
      double buyPrice = OrderPrice(g_buyStopTicket);
      double sellPrice = OrderPrice(g_sellStopTicket);
      g_armMid = NormalizeDouble((buyPrice + sellPrice) / 2.0, _Digits);
      LogInfo(StringFormat("[GM] Recovered armed straddle: BuyStop %s / SellStop %s / mid %s / armed at %s.",
                           PriceStr(buyPrice), PriceStr(sellPrice), PriceStr(g_armMid),
                           TimeToString(g_armTime, TIME_DATE | TIME_MINUTES)));
      LogTransition(g_state, STATE_ARMED);
      g_state = STATE_ARMED;
      return;
     }

   LogInfo("[GM] Recovery: no positions and no pending orders. Starting in STATE_IDLE.");
   LogTransition(g_state, STATE_IDLE);
   g_state = STATE_IDLE;
  }

//+------------------------------------------------------------------+
//|  Event handlers                                                   |
//+------------------------------------------------------------------+
//--- OnInit : validates the environment, caches handles and recovers the live state.
//--- Returns: INIT_SUCCEEDED, INIT_FAILED or INIT_PARAMETERS_INCORRECT.
int OnInit()
  {
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING || marginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
     {
      Print("[GM] INIT FAILED: this Expert Advisor requires a HEDGING account, "
            "but the current account uses netting. No orders will be placed.");
      return INIT_FAILED;
     }

   if(!ValidateInputs())
      return INIT_FAILED;

   if(SpacingMode == SPACING_ATR)
     {
      g_handleGridATR = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
      if(g_handleGridATR == INVALID_HANDLE)
        {
         PrintFormat("[GM] INIT FAILED: iATR(%d) failed, error %d.", ATRPeriod, GetLastError());
         return INIT_FAILED;
        }
     }
   if(UseRangeATRFilter)
     {
      g_handleRangeATR = iATR(_Symbol, PERIOD_CURRENT, RangeATRPeriod);
      if(g_handleRangeATR == INVALID_HANDLE)
        {
         PrintFormat("[GM] INIT FAILED: iATR(%d) for the range filter failed, error %d.",
                     RangeATRPeriod, GetLastError());
         return INIT_FAILED;
        }
     }

   g_trade.SetExpertMagicNumber(EA_MAGIC);
   g_trade.SetDeviationInPoints((ulong)SlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_serverDayIndex = ServerDayIndex();
   g_startOfDayEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_halted = false;
   g_haltReason = "";

   RecoverState();

   PrintFormat("[GM] Initialized on %s (digits=%d, point=%s, spread=%d). Direction is dynamic: "
               "the straddle side that triggers defines the grid direction. Equity=%.2f.",
               _Symbol, _Digits, DoubleToString(_Point, _Digits),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), g_startOfDayEquity);
   return INIT_SUCCEEDED;
  }

//--- OnTick : runs the safety layer and the state machine. Everything is derived live.
//--- Returns: void.
void OnTick()
  {
   // 1) daily bookkeeping (broker server day roll clears halts and resets the equity baseline)
   CheckNewDayRoll();

   // 2) rebuild live grid data (never cached across ticks)
   RebuildGrid();

   // 3) safety layer: equity stop and daily loss close everything and latch a halt
   if(SafetyCheck())
      RebuildGrid();

   // 4) derive the state machine state from live terminal data
   ENUM_STRADDLE_STATE state = DeriveState();

   if(state == STATE_IN_GRID)
     {
      if(g_state != STATE_IN_GRID)
        {
         if(g_state == STATE_ARMED)
            HandleStraddleTrigger();
         else
            LogInfo("[GM] Positions present without an armed straddle (adoption). Managing as grid level 1.");
         CancelAllPending();          // no straddle leg may survive
         FreezeGridATR();             // ATR snapshot for the new grid series
         LogTransition(g_state, state);
         g_state = state;
        }
      ManageInGrid();
      return;
     }

   if(state == STATE_ARMED)
     {
      if(g_state != STATE_ARMED)
        {
         LogTransition(g_state, state);
         g_state = state;
        }
      ManageArmed();
      return;
     }

   if(g_state != STATE_IDLE)
     {
      LogTransition(g_state, state);
      g_state = state;
     }
   ManageIdle();
  }

//--- OnDeinit : releases indicator handles and logs the final state.
//--- reason : deinitialization reason code. Returns: void.
void OnDeinit(const int reason)
  {
   if(g_handleGridATR != INVALID_HANDLE)
     {
      IndicatorRelease(g_handleGridATR);
      g_handleGridATR = INVALID_HANDLE;
     }
   if(g_handleRangeATR != INVALID_HANDLE)
     {
      IndicatorRelease(g_handleRangeATR);
      g_handleRangeATR = INVALID_HANDLE;
     }
   PrintFormat("[GM] Deinit (reason %d). State=%s, halted=%d, open levels=%d, total lots=%.2f, equity=%.2f.",
               reason, StateName(g_state), (int)g_halted, ArraySize(g_grid), SumLots(),
               AccountInfoDouble(ACCOUNT_EQUITY));
  }
//+------------------------------------------------------------------+