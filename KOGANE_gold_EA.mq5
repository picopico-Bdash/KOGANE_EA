//+------------------------------------------------------------------+
//|                                            KOGANE_gold_EA.mq5    |
//|  Entry : HL-ATR Signal + MA Touch Strategy                       |
//|                                                                  |
//|  v1.0 (Initial Production Release)                               |
//|    Strategy:                                                     |
//|      - Cond.1: HL-ATR signal + BB break + MA touch               |
//|      - Cond.2: Camarilla zone reversal (BB + RSI filter)         |
//|    Filters:                                                      |
//|      - H1/M5 trend filters (Cond.2 exempt option)                |
//|      - Time-of-day filter, spread filter                         |
//|      - Daily loss limit, post-SL cooldown                        |
//|    Money management:                                             |
//|      - H1 ATR based SL/TP (M1 ATR fallback selectable)           |
//|      - Auto lot (risk-based) / fixed lot                         |
//|      - Margin usage cap                                          |
//|    Trailing stop (two-phase):                                    |
//|      - Phase 1: N-bar lowest-low / highest-high trail            |
//|        (capped to InpTrailMaxCount updates per position)         |
//|      - Phase 2: peak-ATR Chandelier trail after cap              |
//|        SL = peak high/low offset by InpTrailATR_Multi*ATR        |
//|      - Tracked peak/count stored per position GV                 |
//|      - OnTradeTransaction cleanup on DEAL_ENTRY_OUT/INOUT        |
//|      - OnInit orphan sweep + tester reset                        |
//|    Safety / robustness:                                          |
//|      - STOPS_LEVEL / FREEZE_LEVEL hardened entries               |
//|      - Spread-based fallback for brokers reporting 0             |
//|      - User-configurable safety buffer                           |
//|      - INVALID_STOPS auto-retry with widening                    |
//|      - Frozen-position force-close retry on next tick            |
//|      - Startup broker stops/freeze level diagnostic              |
//|      - Multi-instance lock (magic+symbol GV, heartbeat-based,    |
//|        60-sec stale threshold, skipped in tester/optimizer)      |
//|      - State reconciliation on restart (daily PnL / cooldown /   |
//|        orphaned force-close retry queue)                         |
//|    Optimization:                                                 |
//|      - OnTester() with 5 selectable criteria                     |
//|      - Hard filters (min trades, max DD%, both-side, ratio cap)  |
//|      - Detailed per-pass report                                  |
//|                                                                  |
//|  v1.2 (Trading-hours sessions + Tester perf)                     |
//|    - Trading-hours filter expanded from a single window to       |
//|      three independent sessions: Asia / Europe / America.        |
//|      Each session has its own enable flag + start/end hour.      |
//|      OR-combined: a tick is allowed if ANY enabled session       |
//|      contains the current hour.                                  |
//|      Server time is the reference (sub-hour granularity is not   |
//|      needed for session boundaries).                             |
//|      If InpTimeFilterEnable=true and ALL sessions are OFF, the   |
//|      EA refuses to trade (safe-default; prevents accidental      |
//|      24h trading from a misconfigured fresh install).            |
//|      Defaults (server time, GMT+3 standard):                     |
//|        Asia    02-05  (Tokyo / Sydney quiet hours)               |
//|        Europe  08-10  (London open)                              |
//|        America 14-19  (NY pre-market / US data releases)         |
//|      Each session supports day-wrap (start > end) like before.   |
//|    - UpdatePanel() skipped in tester/optimizer (non-visual)      |
//|      to eliminate per-tick ObjectCreate/SetInteger/ChartRedraw   |
//|      overhead. Trading logic completely unchanged — panel        |
//|      updates were a read-only side effect (the only state they   |
//|      modified, g_panelZone/H1/M5/HLATR/GateOk/MarginOk, is for   |
//|      display only and recomputed from sources every entry pass). |
//|      Visual-mode testing still shows the panel as before.        |
//|                                                                  |
//|  v1.3 (Entry-TF parameterization + filter rework)                |
//|    - Entry timeframe is now a parameter (InpEntryTF, default M1).|
//|      All Cond.1/Cond.2 indicators (ATR1/2, BB1/2/2s, MA, RSI),   |
//|      the new-bar detector, price arrays, and the trailing-stop   |
//|      low/high reference all follow InpEntryTF. Logic unchanged,  |
//|      only the timeframe the bars are read from is configurable.  |
//|      (SL/TP "H1 ATR" source is independent and stays on H1.)     |
//|    - M5 confirmation filter REMOVED entirely (handle, function,  |
//|      params, panel row, init/diag logs, entry checks).           |
//|    - H1 EMA Fast/Slow cross filter REPLACED by two filters,      |
//|      AND-combined on the entry direction:                        |
//|        (A) D1 direction filter:                                  |
//|              Bid > D1 bar0 open  -> BUY-only                      |
//|              Bid < D1 bar0 open  -> SELL-only                     |
//|            (current day candle; Bid used as live close.)         |
//|        (B) Higher-TF EMA filter (timeframe = InpTF_Period):      |
//|              BUY  : EMA[bar2] < EMA[bar1]  AND  bar1 bullish      |
//|              SELL : EMA[bar2] > EMA[bar1]  AND  bar1 bearish      |
//|            bar1 = last closed InpTF_Period bar (Close vs Open).   |
//|            Both the timeframe and EMA period are parameters.      |
//|      Each filter has its own enable flag and Cond.2-exempt flag. |
//|      When a filter is enabled it must ACTIVELY confirm the side;  |
//|      a no-signal (0) state blocks that direction.                |
//|    - Per-condition BUY/SELL toggles: InpEntry1Buy/Sell and       |
//|      InpEntry2Buy/Sell. AND-combined with InpEntryXEnable, they   |
//|      gate ENTRY generation only; exits (HL-ATR exit, trailing,    |
//|      daily-loss force-close) stay active regardless so existing  |
//|      positions always close normally.                            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Kogane"
#property link      ""
#property version   "2.00"
#property description "HL-ATR Signal + BB Break + MA Touch + Camarilla Zone Reversal (Stops-hardened, OnTester custom, Multi-instance lock, Restart-safe)"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//==================================================================
//  Input Parameters
//==================================================================

input group "=== General Settings ==="
input int      InpMagicNumber      = 20250101;     // Magic Number
input int      InpSlippage         = 10;            // Slippage (points)

input group "=== Entry Timeframe ==="
//------------------------------------------------------------------
//  Timeframe the Cond.1/Cond.2 entry logic operates on. Changing
//  this also changes how often the logic runs (one pass per new bar
//  of this timeframe). All entry indicators and the trailing-stop
//  low/high reference follow this. Default M1 keeps legacy behavior.
//------------------------------------------------------------------
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M1;     // Entry timeframe (Cond.1/2 indicators & bars)

input group "=== Lot Management ==="
input bool     InpAutoLot          = true;          // Auto Lot
input double   InpMarginPct        = 100.0;         // Balance usage rate (%)
input double   InpRiskPct          = 5.0;           // Risk per trade (%)
input double   InpMinLotOverride   = 0.0;           // Min lot override (0.0=broker min)
input double   InpFixedLot         = 0.1;           // Fixed lot size
input double   InpMaxLot           = 10.0;          // Max lot size

input group "=== Cond.1: Core Settings ==="
input bool     InpEntry1Enable     = true;          // Enable Condition 1
input bool     InpEntry1Buy        = true;          // Cond.1 allow BUY
input bool     InpEntry1Sell       = true;          // Cond.1 allow SELL
input ENUM_MA_METHOD InpMA_Method  = MODE_EMA;      // MA mode
input int      InpMA_Period        = 10;            // MA period
input double   InpMA_Touch_Buffer  = 0.15;          // MA touch tolerance (ATR multiplier)
input int      InpATR1_Period      = 14;            // ATR period
input int      InpBB1_Period       = 20;            // BB period
input double   InpBB1_Deviation    = 2.0;           // BB standard deviation

input group "=== Cond.1: Signal ==="
input double   InpHLATR_Signal     = 2.0;           // Signal trigger HL-ATR
input double   InpHLATR_Cancel     = 1.5;           // Signal cancel HL-ATR
input int      InpSignalExpiry     = 10;            // Signal expiry (M1 bars, 0=unlimited)

input group "=== Cond.1: Entry Filter ==="
input bool     InpPullbackQuality  = true;          // Pullback quality (buy:bullish / sell:bearish touch)
input double   InpEntryHLATR_Max   = 0.8;           // Max HL-ATR at entry (0=unlimited)

input group "=== Cond.2: ATR + BB (+-2SD Reversal) + Camarilla Pivot ==="
input bool     InpEntry2Enable     = true;          // Enable Condition 2
input bool     InpEntry2Buy        = true;          // Cond.2 allow BUY
input bool     InpEntry2Sell       = true;          // Cond.2 allow SELL
input int      InpATR2_Period      = 14;            // ATR period
input int      InpRSI_Period       = 14;            // RSI period (Cond.2)
input int      InpBB2_Period       = 20;            // BB period
input double   InpBB2_Deviation    = 2.0;           // BB standard deviation
input double   InpBB2_Dev1         = 2.0;           // Close BB inner band (xSD)
input double   InpHLATR_Reversal   = 2.0;           // HL-ATR threshold
input bool     InpCamarillaEnable  = true;          // Enable Camarilla filter
input double   InpCamNearATR       = 1.0;           // Level proximity (ATR multiplier)
input double   InpC2_RSI_Buy       = 30.0;          // Buy RSI threshold (below)
input double   InpC2_RSI_Sell      = 70.0;          // Sell RSI threshold (above)
input bool     InpCamZoneTP        = true;          // Use opposite zone level as TP

input group "=== TP / SL Settings ==="
input double   InpSL_ATR_Multi     = 0.5;           // Stop Loss (ATR multiplier)

enum ENUM_TP_MODE
{
   TP_ATR_ONLY     = 0,
   TP_HLATR_SIGNAL = 1,
   TP_BOTH         = 2,
};
input ENUM_TP_MODE InpTP_Mode       = TP_BOTH;      // Take Profit mode
input double   InpTP_ATR_Multi      = 2.0;          // Take Profit (ATR multiplier)
input double   InpHLATR_ExitA       = 2.5;          // HL-ATR exit: bearish candle threshold
input double   InpHLATR_ExitB       = 2.5;          // HL-ATR exit: bullish candle threshold

//--- SL/TP ATR source ---
enum ENUM_SLTP_ATR_SOURCE
{
   SLTP_ATR_M1  = 0,   // Entry-TF ATR (follows InpEntryTF)
   SLTP_ATR_H1  = 1,   // H1 ATR (recommended for Gold)
};
input ENUM_SLTP_ATR_SOURCE InpSLTP_ATRSource = SLTP_ATR_H1;   // ATR source

input group "=== Trailing Stop ==="
input bool     InpTrailEnable      = true;          // Enable trailing stop
input int      InpTrailBars        = 10;            // Trail bars (lowest low / highest high)
input int      InpTrailMaxCount    = 3;             // Max trailing updates per position (0=unlimited)
input double   InpTrailATR_Multi   = 2.5;           // Phase 2: SL offset = (peak high/low) - ATR x this multi

input group "=== Stop Level Safety ==="
input int      InpStopsBufferPoints = 5;            // Extra safety buffer (points) on top of broker stops level
input bool     InpStopsUseSpreadFallback = true;    // Use current spread as fallback when broker stops level=0
input double   InpStopsSpreadMulti  = 2.0;          // Spread multiplier for fallback (e.g. 2.0 = 2x current spread)
input int      InpInvalidStopsRetry = 2;            // Retry count when entry fails with INVALID_STOPS
input int      InpFreezeRetryBars   = 3;            // Re-attempt force-close every N bars when frozen

input group "=== Custom Optimization Criterion (OnTester) ==="
enum ENUM_TESTER_MODE
{
   TESTER_DEFAULT      = 0,   // Use built-in metric (Profit Factor)
   TESTER_RECOVERY     = 1,   // Recovery Factor (NetProfit / MaxDD)
   TESTER_SHARPE       = 2,   // Sharpe Ratio
   TESTER_COMPOSITE    = 3,   // Composite: Profit x PF x sqrt(N) x (1 - DD%)
   TESTER_RISK_ADJUSTED= 4,   // NetProfit / MaxDD%, with trade-count gate
};
input ENUM_TESTER_MODE InpTesterMode  = TESTER_COMPOSITE;  // Optimization criterion
input int      InpTesterMinTrades     = 50;        // Hard filter: minimum total trades (lower => DBL_MIN)
input double   InpTesterMaxDDPercent  = 30.0;      // Hard filter: maximum allowed equity DD% (higher => DBL_MIN)
input double   InpTesterMinProfit     = 0.0;       // Hard filter: minimum net profit (lower => DBL_MIN)
input bool     InpTesterRequireBothSides = true;   // Require both long & short trades to exist
input double   InpTesterMaxSideRatio  = 0.85;      // Reject if any direction takes >X% of trades (overfit guard)
input bool     InpTesterPrintReport   = true;      // Print detailed report at end of each pass

//==================================================================
//  Filters
//==================================================================
input group "=== D1 Direction Filter ==="
//------------------------------------------------------------------
//  Current-day (D1 bar0) direction gate:
//    Bid > D1 bar0 open  -> only BUY allowed
//    Bid < D1 bar0 open  -> only SELL allowed
//  Uses Bid as the live close of the still-forming daily candle.
//------------------------------------------------------------------
input bool     InpD1FilterEnable   = true;          // Enable D1 direction filter
input bool     InpD1_Cond2Exempt   = true;          // Cond.2 (reversal) exempt from D1 filter

input group "=== Higher-TF EMA Filter ==="
//------------------------------------------------------------------
//  EMA slope + price-position gate on a configurable timeframe:
//    BUY  : EMA[bar2] < EMA[bar1] (rising)  AND  EMA[bar1] < Bid
//    SELL : EMA[bar2] > EMA[bar1] (falling) AND  EMA[bar1] > Bid
//  bar1 = last closed bar, bar2 = the one before it.
//------------------------------------------------------------------
input bool            InpTFFilterEnable = true;     // Enable higher-TF EMA filter
input ENUM_TIMEFRAMES InpTF_Period      = PERIOD_H1;// Filter timeframe
input int             InpTF_EMA_Period  = 5;        // EMA period
input bool            InpTF_Cond2Exempt = true;     // Cond.2 (reversal) exempt from TF filter

input group "=== Cooldown (Post Stop-Loss Lockout) ==="
input bool     InpCooldownEnable   = true;          // Enable cooldown
input int      InpCooldownMinutes  = 30;            // Cooldown duration (minutes)

input group "=== Daily Loss Limit ==="
input bool     InpDailyLossEnable  = true;          // Enable daily loss limit
input double   InpDailyLossMaxPct  = 3.0;           // Max daily loss (% of balance)
input bool     InpDailyLossCloseAll= false;         // Close all positions on limit hit

input group "=== Trading Hours: Master + Cond.1 (Server Time, 3 sessions) ==="
//------------------------------------------------------------------
//  Per-condition trading-hour windows. The master switch gates both.
//  Each condition has its own Asia/Europe/America sessions, OR-combined:
//    a bar is allowed for that condition if ANY of its enabled sessions
//    contains the current hour.
//  If InpTimeFilterEnable=true but a condition has NO effective session,
//  that condition never trades on time grounds (safe-default). If BOTH
//  conditions have no effective session, OnInit rejects the parameters.
//  Day-wrap supported per session (e.g. 22-3 = 22h..23h + 0h..2h).
//  Defaults assume GMT+3 server time:
//    Asia 02-05  Europe 08-10  America 14-19 (US data window)
//------------------------------------------------------------------
input bool     InpTimeFilterEnable    = true;       // Enable time filter (master, both conds)
input bool     InpTime1AsiaEnable     = true;       // [C1] Asia session enable
input int      InpTime1AsiaStart      = 2;          // [C1] Asia start hour (server time)
input int      InpTime1AsiaEnd        = 9;          // [C1] Asia end hour
input bool     InpTime1EuropeEnable   = true;       // [C1] Europe session enable
input int      InpTime1EuropeStart    = 14;         // [C1] Europe start hour
input int      InpTime1EuropeEnd      = 17;         // [C1] Europe end hour
input bool     InpTime1AmericaEnable  = true;       // [C1] America session enable
input int      InpTime1AmericaStart   = 21;         // [C1] America start hour
input int      InpTime1AmericaEnd     = 23;         // [C1] America end hour

input group "=== Trading Hours: Cond.2 (Server Time, 3 sessions) ==="
input bool     InpTime2AsiaEnable     = false;      // [C2] Asia session enable
input int      InpTime2AsiaStart      = 0;          // [C2] Asia start hour (server time)
input int      InpTime2AsiaEnd        = 23;         // [C2] Asia end hour
input bool     InpTime2EuropeEnable   = true;       // [C2] Europe session enable
input int      InpTime2EuropeStart    = 9;          // [C2] Europe start hour
input int      InpTime2EuropeEnd      = 12;         // [C2] Europe end hour
input bool     InpTime2AmericaEnable  = true;       // [C2] America session enable
input int      InpTime2AmericaStart   = 14;         // [C2] America start hour
input int      InpTime2AmericaEnd     = 19;         // [C2] America end hour

input group "=== Spread Filter ==="
input bool     InpSpreadFilterEnable = true;        // Enable spread filter
input int      InpMaxSpreadPoints  = 50;            // Max spread (points)

input group "=== Filters / Logging ==="
input bool     InpOnlyOnePos       = false;         // One position per condition
input bool     InpPrintLog         = false;         // Enable trade log
input bool     InpDiagLog          = false;         // Enable diagnostic log
input int      InpWarmupBars       = 30;            // Warmup bars

input group "=== Safety: Multi-Instance Lock ==="
//------------------------------------------------------------------
//  Prevents two EA instances with the SAME magic + SAME symbol from
//  running simultaneously. Uses a GlobalVariable lock with periodic
//  heartbeat. Stale locks (no heartbeat for >60s) are taken over
//  automatically (e.g., after a crash). Skipped in tester/optimizer.
//  Disable only if you intentionally need multi-instance setups.
//------------------------------------------------------------------
input bool     InpMagicConflictCheck = true;        // Block duplicate magic+symbol instances

input group "=== Safety: State Reconciliation ==="
//------------------------------------------------------------------
//  After a restart (network drop, terminal close, recompile), restore
//  daily PnL / cooldown state from broker deal history so safety
//  limits cannot be reset by simply reloading the EA.
//  Note: g_dailyStartBalance is approximated from THIS EA's PnL only.
//  External activity (manual trades, other EAs, deposits) is ignored.
//  Skipped in tester/optimizer.
//------------------------------------------------------------------
input bool     InpReconcileOnInit  = true;          // Reconcile state from history on startup

//==================================================================
//  Global Variables
//==================================================================

int           g_hATR1        = INVALID_HANDLE;
int           g_hBB1         = INVALID_HANDLE;
int           g_hRSI         = INVALID_HANDLE;
int           g_hATR2        = INVALID_HANDLE;
int           g_hBB2         = INVALID_HANDLE;
int           g_hBB2s        = INVALID_HANDLE;
int           g_hMA          = INVALID_HANDLE;

// Higher timeframe handles
int           g_hTF_EMA      = INVALID_HANDLE;   // Higher-TF EMA filter
int           g_hH1_ATR      = INVALID_HANDLE;   // H1 ATR (SL/TP source, independent of entry TF)

bool          g_buySignal    = false;
bool          g_sellSignal   = false;

// Signal bar counters
int           g_buySignalBar  = 0;
int           g_sellSignalBar = 0;

datetime      g_lastBarTime  = 0;
int           g_barCount     = 0;

// Cooldown
datetime      g_cooldownUntil = 0;

// Daily loss limit
datetime      g_dailyLossDate       = 0;
double        g_dailyPnL            = 0.0;
double        g_dailyStartBalance   = 0.0;
bool          g_dailyLossLocked     = false;

// Force-close retry state (for positions that were frozen when CloseAllPositions ran)
bool          g_pendingForceClose   = false;
int           g_lastForceCloseBar   = 0;

// Multi-instance lock (heartbeat-based)
datetime      g_lastHeartbeat       = 0;
bool          g_lockAcquired        = false;

// Reconcile diagnostics (panel display)
bool          g_reconciledDaily     = false;
bool          g_reconciledCooldown  = false;

// Camarilla pivots (all levels)
datetime      g_camarillaDate  = 0;
double        g_camR5 = 0.0, g_camR4 = 0.0, g_camR3 = 0.0, g_camR2 = 0.0, g_camR1 = 0.0;
double        g_camS1 = 0.0, g_camS2 = 0.0, g_camS3 = 0.0, g_camS4 = 0.0, g_camS5 = 0.0;
double        g_camPivot = 0.0;

// Panel cache
int           g_panelD1       = 0;     // +1=BUY, -1=SELL, 0=--
int           g_panelTF       = 0;     // +1=BUY, -1=SELL, 0=--
bool          g_panelGateOk   = true;
bool          g_panelMarginOk = true;
double        g_panelHLATR    = 0.0;
string        g_panelZone     = "--";

#define PANEL_PREFIX "KogPanel_"

CTrade        g_trade;
CPositionInfo g_posInfo;

#define COMMENT_COND1_BUY   "Kogane_Buy"
#define COMMENT_COND1_SELL  "Kogane_Sell"
#define COMMENT_COND2_BUY   "Kogane_Buy_Rev"
#define COMMENT_COND2_SELL  "Kogane_Sell_Rev"


//==================================================================
//  Multi-instance lock (GlobalVariable + heartbeat)
//------------------------------------------------------------------
//  Prevents two EA instances on the same magic+symbol from racing.
//  - Lock value = TimeCurrent() at last heartbeat
//  - Stale threshold = 60 sec (give 2x heartbeat-interval margin)
//  - Heartbeat interval = 30 sec (refreshed from OnTick)
//  - Skipped entirely in tester/optimizer (validator-friendly)
//==================================================================
#define KOGANE_LOCK_STALE_SECS    60
#define KOGANE_LOCK_HEARTBEAT_SECS 30

string MagicLockKey()
{
   // GlobalVariable name limit is 63 chars. Symbol+magic is well under.
   return StringFormat("KOGANE_GOLD_LOCK_%s_%d", _Symbol, InpMagicNumber);
}

bool AcquireMagicLock()
{
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) return true;
   if(!InpMagicConflictCheck) return true;

   string key = MagicLockKey();

   if(GlobalVariableCheck(key))
   {
      datetime prevTs = (datetime)GlobalVariableGet(key);
      datetime now    = TimeCurrent();
      int      age    = (int)(now - prevTs);

      // Negative age = clock skew or future-dated lock. Treat as stale.
      if(age >= 0 && age < KOGANE_LOCK_STALE_SECS)
      {
         PrintFormat("ERROR: Magic conflict detected. Another instance with magic=%d on %s "
                     "has a heartbeat %d sec ago (stale threshold=%d sec). "
                     "Use a different magic, stop the other instance, or wait %d sec for stale takeover. "
                     "To bypass entirely, set InpMagicConflictCheck=false.",
                     InpMagicNumber, _Symbol, age,
                     KOGANE_LOCK_STALE_SECS, KOGANE_LOCK_STALE_SECS - age);
         return false;
      }

      if(InpPrintLog)
         PrintFormat("[Lock] Stale lock takeover (prev heartbeat %d sec ago)", age);
   }

   GlobalVariableSet(key, (double)TimeCurrent());
   g_lockAcquired  = true;
   g_lastHeartbeat = TimeCurrent();
   if(InpPrintLog) PrintFormat("[Lock] Acquired: %s", key);
   return true;
}

void RefreshMagicLock()
{
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) return;
   if(!InpMagicConflictCheck || !g_lockAcquired) return;

   datetime now = TimeCurrent();
   if(now - g_lastHeartbeat < KOGANE_LOCK_HEARTBEAT_SECS) return;

   GlobalVariableSet(MagicLockKey(), (double)now);
   g_lastHeartbeat = now;
}

void ReleaseMagicLock()
{
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) return;
   if(!g_lockAcquired) return;

   string key = MagicLockKey();
   if(GlobalVariableCheck(key))
   {
      GlobalVariableDel(key);
      if(InpPrintLog) PrintFormat("[Lock] Released: %s", key);
   }
   g_lockAcquired = false;
}

//==================================================================
//  Trailing-stop update counter (per position, GlobalVariable based)
//------------------------------------------------------------------
//  Caps how many times the SL is moved in the profit direction by
//  the trailing-stop logic. The intent is to "lock in profit" by
//  preventing the SL from being trailed indefinitely.
//
//  Counter lifecycle:
//   - Start: 0 (no GV created at entry; absent => 0)
//   - +1   : on every successful PositionModify in trailing block
//   - Del  : on DEAL_ENTRY_OUT/INOUT (OnTradeTransaction)
//   - Del  : OnInit orphan sweep (positions no longer existing)
//   - Del  : OnInit tester reset (always clear in tester/optimizer)
//
//  Naming: KOGN_TRAILCNT_<magic>_<position_ticket>
//  Scope : per magic so multiple EA instances don't collide.
//==================================================================
string TrailCntPrefix()
{
   return StringFormat("KOGN_TRAILCNT_%d_", InpMagicNumber);
}

string TrailCntKey(const ulong positionTicket)
{
   return StringFormat("%s%I64u", TrailCntPrefix(), positionTicket);
}

int TrailCntGet(const ulong positionTicket)
{
   string key = TrailCntKey(positionTicket);
   if(!GlobalVariableCheck(key)) return 0;
   return (int)GlobalVariableGet(key);
}

void TrailCntSet(const ulong positionTicket, const int count)
{
   GlobalVariableSet(TrailCntKey(positionTicket), (double)count);
}

//------------------------------------------------------------------
//  Sweep all KOGN_TRAILCNT_<magic>_* GVs whose position no longer
//  exists. Called from OnInit to clean up after crashes/recompiles.
//------------------------------------------------------------------
void TrailCntSweepOrphans()
{
   string prefix = TrailCntPrefix();
   int total = GlobalVariablesTotal();
   int deleted = 0;

   // Iterate in reverse because deletion shifts indices.
   for(int i = total - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, prefix) != 0) continue;     // not ours

      string tail   = StringSubstr(name, StringLen(prefix));
      ulong  ticket = (ulong)StringToInteger(tail);
      if(ticket == 0) { GlobalVariableDel(name); deleted++; continue; }

      // PositionSelectByTicket returns true only if position is open.
      if(!PositionSelectByTicket(ticket))
      {
         GlobalVariableDel(name);
         deleted++;
      }
   }

   if(InpPrintLog && deleted > 0)
      PrintFormat("[TrailCnt] Sweep removed %d orphan counter(s)", deleted);
}

//------------------------------------------------------------------
//  In tester/optimizer, always start clean. Without this, leftover
//  GVs from a prior pass would corrupt subsequent passes.
//------------------------------------------------------------------
void TrailCntResetForTester()
{
   if(!MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_OPTIMIZATION)) return;

   string prefix = TrailCntPrefix();
   int total = GlobalVariablesTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, prefix) == 0) GlobalVariableDel(name);
   }
}

//==================================================================
//  Phase-2 peak tracker (per position, GlobalVariable based)
//------------------------------------------------------------------
//  Stores the highest (BUY) or lowest (SELL) M1 bar value seen
//  since this position entered Phase 2 (i.e. since the trail counter
//  reached InpTrailMaxCount). The Chandelier-style SL is derived as:
//      BUY  : SL = trackedMax - ATR(M1) * InpTrailATR_Multi
//      SELL : SL = trackedMin + ATR(M1) * InpTrailATR_Multi
//
//  Same lifecycle as TrailCnt:
//   - +Update : every Phase-2 tick (replaced with new high/low)
//   - Del     : on DEAL_ENTRY_OUT/INOUT (OnTradeTransaction)
//   - Del     : OnInit orphan sweep / tester reset
//
//  Naming: KOGN_TRAILEXT_<magic>_<position_ticket>
//  Sentinel: 0.0 means "not initialized yet" (Gold price is never 0)
//==================================================================
string TrailExtPrefix()
{
   return StringFormat("KOGN_TRAILEXT_%d_", InpMagicNumber);
}

string TrailExtKey(const ulong positionTicket)
{
   return StringFormat("%s%I64u", TrailExtPrefix(), positionTicket);
}

double TrailExtGet(const ulong positionTicket)
{
   string key = TrailExtKey(positionTicket);
   if(!GlobalVariableCheck(key)) return 0.0;
   return GlobalVariableGet(key);
}

void TrailExtSet(const ulong positionTicket, const double value)
{
   GlobalVariableSet(TrailExtKey(positionTicket), value);
}

void TrailExtSweepOrphans()
{
   string prefix = TrailExtPrefix();
   int total = GlobalVariablesTotal();
   int deleted = 0;

   for(int i = total - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, prefix) != 0) continue;

      string tail   = StringSubstr(name, StringLen(prefix));
      ulong  ticket = (ulong)StringToInteger(tail);
      if(ticket == 0) { GlobalVariableDel(name); deleted++; continue; }

      if(!PositionSelectByTicket(ticket))
      {
         GlobalVariableDel(name);
         deleted++;
      }
   }

   if(InpPrintLog && deleted > 0)
      PrintFormat("[TrailExt] Sweep removed %d orphan tracker(s)", deleted);
}

void TrailExtResetForTester()
{
   if(!MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_OPTIMIZATION)) return;

   string prefix = TrailExtPrefix();
   int total = GlobalVariablesTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, prefix) == 0) GlobalVariableDel(name);
   }
}

//==================================================================
//  State reconciliation
//------------------------------------------------------------------
//  On startup (after network drop, restart, recompile, etc.) restore
//  daily PnL/cooldown/force-close state from broker deal history.
//  Without this, safety limits could be circumvented by simply
//  reloading the EA.
//
//  Approximations:
//   - g_dailyStartBalance = currentBalance - SUM(thisEA today)
//     (ignores manual trades / other EAs / deposits — acceptable
//      because we want "this EA's daily impact" not "total impact")
//
//  Skipped in tester/optimizer.
//==================================================================
void ReconcileDailyPnL()
{
   if(!InpDailyLossEnable) return;

   MqlDateTime dtNow;
   TimeCurrent(dtNow);
   datetime today = (datetime)(TimeCurrent() - dtNow.hour*3600 - dtNow.min*60 - dtNow.sec);

   if(!HistorySelect(today, TimeCurrent()))
   {
      if(InpPrintLog) Print("[Reconcile] HistorySelect failed for daily PnL");
      return;
   }

   double todayPnL = 0.0;
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC)  != InpMagicNumber) continue;
      if(HistoryDealGetString (dealTicket, DEAL_SYMBOL) != _Symbol)        continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      todayPnL += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   }

   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyStartBalance   = currentBalance - todayPnL;
   g_dailyPnL            = todayPnL;
   g_dailyLossDate       = today;
   g_dailyLossLocked     = false;

   if(g_dailyStartBalance > 0.0 && todayPnL < 0.0)
   {
      double lossPct = -todayPnL / g_dailyStartBalance * 100.0;
      g_dailyLossLocked = (lossPct >= InpDailyLossMaxPct);
   }

   g_reconciledDaily = true;

   if(InpPrintLog)
      PrintFormat("[Reconcile Daily] Date=%s StartBal~=%.2f PnL=%.2f Locked=%s",
                  TimeToString(today, TIME_DATE),
                  g_dailyStartBalance, g_dailyPnL,
                  g_dailyLossLocked ? "YES" : "NO");
}

void ReconcileCooldown()
{
   if(!InpCooldownEnable) return;

   datetime from = TimeCurrent() - InpCooldownMinutes * 60;
   datetime to   = TimeCurrent();
   if(!HistorySelect(from, to))
   {
      if(InpPrintLog) Print("[Reconcile] HistorySelect failed for cooldown");
      return;
   }

   int totalDeals = HistoryDealsTotal();
   datetime mostRecentLossTime = 0;
   double   mostRecentLossPnL  = 0.0;

   // Iterate newest-to-oldest; first loss within window wins.
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC)  != InpMagicNumber) continue;
      if(HistoryDealGetString (dealTicket, DEAL_SYMBOL) != _Symbol)        continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                    + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                    + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      if(profit >= 0.0) continue;

      mostRecentLossTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      mostRecentLossPnL  = profit;
      break;
   }

   if(mostRecentLossTime > 0)
   {
      datetime cooldownEnd = mostRecentLossTime + InpCooldownMinutes * 60;
      if(cooldownEnd > TimeCurrent())
      {
         g_cooldownUntil      = cooldownEnd;
         g_reconciledCooldown = true;
         if(InpPrintLog)
            PrintFormat("[Reconcile Cooldown] Loss=%.2f at %s -> Lock until %s",
                        mostRecentLossPnL,
                        TimeToString(mostRecentLossTime, TIME_DATE | TIME_MINUTES),
                        TimeToString(cooldownEnd,        TIME_DATE | TIME_MINUTES));
      }
   }
}

void ReconcileOrphanedForceClose()
{
   // If daily limit was locked AND close-all-on-limit is enabled AND
   // EA still has open positions, queue a force-close retry.
   // (This handles the case where CloseAllPositions partially failed
   //  before the EA was killed.)
   if(!g_dailyLossLocked || !InpDailyLossCloseAll) return;

   bool hasOpen = false;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString (POSITION_SYMBOL) != _Symbol)        continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagicNumber) continue;
      hasOpen = true;
      break;
   }

   if(hasOpen)
   {
      g_pendingForceClose = true;
      if(InpPrintLog)
         Print("[Reconcile] Daily limit locked + positions open -> queued force-close");
   }
}

void ReconcileState()
{
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) return;
   if(!InpReconcileOnInit) return;

   ReconcileDailyPnL();
   ReconcileCooldown();
   ReconcileOrphanedForceClose();
}

//==================================================================
//  Timeframe -> short string (e.g. PERIOD_H1 -> "H1") for logging
//==================================================================
string TFToStr(const ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);          // "PERIOD_H1"
   int p = StringFind(s, "PERIOD_");
   if(p == 0) s = StringSubstr(s, 7);    // -> "H1"
   return s;
}

//==================================================================
//  OnInit
//==================================================================
int OnInit()
{
   if(InpAutoLot)
   {
      if(InpMarginPct <= 0.0 || InpMarginPct > 100.0)
      { Print("ERROR: InpMarginPct must be 0 < x <= 100"); return INIT_PARAMETERS_INCORRECT; }
      if(InpRiskPct <= 0.0 || InpRiskPct > 100.0)
      { Print("ERROR: InpRiskPct must be 0 < x <= 100");   return INIT_PARAMETERS_INCORRECT; }
   }
   if(InpTrailBars < 1)
   { Print("ERROR: InpTrailBars must be >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTrailMaxCount < 0)
   { Print("ERROR: InpTrailMaxCount must be >= 0 (0=unlimited)"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTrailATR_Multi <= 0.0)
   { Print("ERROR: InpTrailATR_Multi must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTrailMaxCount == 0)
      Print("WARNING: InpTrailMaxCount=0 (unlimited Phase 1) -> Phase 2 (ATR-based trail) will never activate");
   if(InpTimeFilterEnable)
   {
      // Each session: start==end is treated as "empty window" (effectively disabled).
      // Per condition we allow all-off silently (that condition just won't trade on
      // time grounds). We only ERROR if BOTH conditions have no effective session,
      // because then nothing could ever trade and the cause would be non-obvious.
      bool c1Asia    = InpTime1AsiaEnable    && (InpTime1AsiaStart    != InpTime1AsiaEnd);
      bool c1Europe  = InpTime1EuropeEnable  && (InpTime1EuropeStart  != InpTime1EuropeEnd);
      bool c1America = InpTime1AmericaEnable && (InpTime1AmericaStart != InpTime1AmericaEnd);
      bool c2Asia    = InpTime2AsiaEnable    && (InpTime2AsiaStart    != InpTime2AsiaEnd);
      bool c2Europe  = InpTime2EuropeEnable  && (InpTime2EuropeStart  != InpTime2EuropeEnd);
      bool c2America = InpTime2AmericaEnable && (InpTime2AmericaStart != InpTime2AmericaEnd);

      bool c1Any = c1Asia || c1Europe || c1America;
      bool c2Any = c2Asia || c2Europe || c2America;

      if(!c1Any && !c2Any)
      {
         Print("ERROR: InpTimeFilterEnable=true but neither Cond.1 nor Cond.2 has an "
               "effective session. Enable at least one session (start!=end) on a condition, "
               "or set InpTimeFilterEnable=false.");
         return INIT_PARAMETERS_INCORRECT;
      }

      // Range checks (hours must be 0..23)
      if(InpTime1AsiaStart    < 0 || InpTime1AsiaStart    > 23 ||
         InpTime1AsiaEnd      < 0 || InpTime1AsiaEnd      > 23 ||
         InpTime1EuropeStart  < 0 || InpTime1EuropeStart  > 23 ||
         InpTime1EuropeEnd    < 0 || InpTime1EuropeEnd    > 23 ||
         InpTime1AmericaStart < 0 || InpTime1AmericaStart > 23 ||
         InpTime1AmericaEnd   < 0 || InpTime1AmericaEnd   > 23 ||
         InpTime2AsiaStart    < 0 || InpTime2AsiaStart    > 23 ||
         InpTime2AsiaEnd      < 0 || InpTime2AsiaEnd      > 23 ||
         InpTime2EuropeStart  < 0 || InpTime2EuropeStart  > 23 ||
         InpTime2EuropeEnd    < 0 || InpTime2EuropeEnd    > 23 ||
         InpTime2AmericaStart < 0 || InpTime2AmericaStart > 23 ||
         InpTime2AmericaEnd   < 0 || InpTime2AmericaEnd   > 23)
      {
         Print("ERROR: Session start/end hours must be in 0..23");
         return INIT_PARAMETERS_INCORRECT;
      }
   }
   if(InpDailyLossEnable && InpDailyLossMaxPct <= 0.0)
   { Print("ERROR: InpDailyLossMaxPct must be greater than 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTFFilterEnable && InpTF_EMA_Period < 1)
   { Print("ERROR: InpTF_EMA_Period must be >= 1"); return INIT_PARAMETERS_INCORRECT; }

   //--- Acquire multi-instance lock BEFORE allocating indicator handles
   //    so we don't waste resources if another instance already holds it.
   if(!AcquireMagicLock())
      return INIT_FAILED;

   // Entry-TF indicators (timeframe = InpEntryTF)
   g_hATR1 = iATR  (_Symbol, InpEntryTF, InpATR1_Period);
   g_hBB1  = iBands(_Symbol, InpEntryTF, InpBB1_Period,  0, InpBB1_Deviation,  PRICE_CLOSE);
   g_hRSI  = iRSI  (_Symbol, InpEntryTF, InpRSI_Period,  PRICE_CLOSE);
   g_hATR2 = iATR  (_Symbol, InpEntryTF, InpATR2_Period);
   g_hBB2  = iBands(_Symbol, InpEntryTF, InpBB2_Period,  0, InpBB2_Deviation,  PRICE_CLOSE);
   g_hBB2s = iBands(_Symbol, InpEntryTF, InpBB2_Period,  0, InpBB2_Dev1,       PRICE_CLOSE);
   g_hMA   = iMA   (_Symbol, InpEntryTF, InpMA_Period,   0, InpMA_Method,      PRICE_CLOSE);

   // Higher-TF EMA filter (timeframe = InpTF_Period)
   g_hTF_EMA = iMA(_Symbol, InpTF_Period, InpTF_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   // H1 ATR for SL/TP source (independent of entry/filter timeframes)
   g_hH1_ATR = iATR(_Symbol, PERIOD_H1, 14);

   if(g_hATR1 == INVALID_HANDLE || g_hBB1  == INVALID_HANDLE ||
      g_hRSI  == INVALID_HANDLE ||
      g_hATR2 == INVALID_HANDLE || g_hBB2  == INVALID_HANDLE ||
      g_hBB2s == INVALID_HANDLE || g_hMA   == INVALID_HANDLE ||
      g_hTF_EMA == INVALID_HANDLE || g_hH1_ATR == INVALID_HANDLE)
   { Print("ERROR: Failed to create indicator handles"); return INIT_FAILED; }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippage);

   ENUM_ORDER_TYPE_FILLING filling =
      (ENUM_ORDER_TYPE_FILLING)(int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if     ((filling & ORDER_FILLING_FOK) != 0) g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & ORDER_FILLING_IOC) != 0) g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                         g_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   // Daily loss limit init
   g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dtNow;
   TimeCurrent(dtNow);
   g_dailyLossDate   = (datetime)(TimeCurrent() - dtNow.hour*3600 - dtNow.min*60 - dtNow.sec);
   g_dailyPnL        = 0.0;
   g_dailyLossLocked = false;

   //--- Reconcile state from broker history (overrides freshly-init values)
   //    Must come AFTER the fresh init above so reconcile values take precedence.
   ReconcileState();

   //--- Trailing-stop counter housekeeping
   //    Tester/optimizer: wipe everything to avoid cross-pass contamination.
   //    Live: drop GVs whose positions no longer exist (post-crash cleanup).
   TrailCntResetForTester();
   TrailCntSweepOrphans();
   TrailExtResetForTester();
   TrailExtSweepOrphans();

   if(InpPrintLog)
   {
      // Broker stop/freeze level info (always log this — critical for diagnosing rejected orders)
      long stopsPts  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      long freezePts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      long curSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double effDist = GetStopsLevelDist();
      PrintFormat("[Broker Stops] StopsLevel=%dpt FreezeLevel=%dpt Spread=%dpt -> Effective min SL/TP dist=%.5f (%.0fpt) buffer=%dpt fallback=%s",
                  (int)stopsPts, (int)freezePts, (int)curSpread,
                  effDist, effDist / _Point,
                  InpStopsBufferPoints,
                  InpStopsUseSpreadFallback ? "ON" : "OFF");

      string accountCcy = AccountInfoString(ACCOUNT_CURRENCY);
      string profitCcy  = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
      string lotMode    = InpAutoLot
         ? StringFormat("AutoLot(Margin%.0f%%xRisk%.1f%%)", InpMarginPct, InpRiskPct)
         : StringFormat("FixedLot%.2f", InpFixedLot);
      string tpMode = (InpTP_Mode == TP_ATR_ONLY)
         ? StringFormat("ATR_TP(x%.1f)", InpTP_ATR_Multi)
         : (InpTP_Mode == TP_HLATR_SIGNAL)
            ? StringFormat("HLATR_Exit(A>=%.1f/B>=%.1f)", InpHLATR_ExitA, InpHLATR_ExitB)
            : StringFormat("HLATR_Exit+ATR_Net(A>=%.1f/B>=%.1f/x%.1f)",
                           InpHLATR_ExitA, InpHLATR_ExitB, InpTP_ATR_Multi);
      string sltpSrc = (InpSLTP_ATRSource == SLTP_ATR_H1) ? "H1_ATR" : "EntryTF_ATR";
      string entryTfInfo = TFToStr(InpEntryTF);
      string d1Filt  = InpD1FilterEnable
         ? StringFormat("D1_Dir C2Exempt=%s", InpD1_Cond2Exempt?"Y":"N")
         : "OFF";
      string tfFilt  = InpTFFilterEnable
         ? StringFormat("%s_EMA(%d) C2Exempt=%s", TFToStr(InpTF_Period), InpTF_EMA_Period, InpTF_Cond2Exempt?"Y":"N")
         : "OFF";
      string cdInfo  = InpCooldownEnable ? StringFormat("%dmin", InpCooldownMinutes) : "OFF";
      string dlInfo  = InpDailyLossEnable ? StringFormat("%.1f%%", InpDailyLossMaxPct) : "OFF";
      string tmInfo;
      if(InpTimeFilterEnable)
      {
         tmInfo = "C1" + SessionSetStr(InpTime1AsiaEnable,    InpTime1AsiaStart,    InpTime1AsiaEnd,
                                       InpTime1EuropeEnable,  InpTime1EuropeStart,  InpTime1EuropeEnd,
                                       InpTime1AmericaEnable, InpTime1AmericaStart, InpTime1AmericaEnd)
                + " C2" + SessionSetStr(InpTime2AsiaEnable,    InpTime2AsiaStart,    InpTime2AsiaEnd,
                                        InpTime2EuropeEnable,  InpTime2EuropeStart,  InpTime2EuropeEnd,
                                        InpTime2AmericaEnable, InpTime2AmericaStart, InpTime2AmericaEnd);
      }
      else tmInfo = "OFF";
      string spInfo  = InpSpreadFilterEnable ? StringFormat("<=%dpt", InpMaxSpreadPoints) : "OFF";
      string c1Info  = StringFormat("Expiry=%s Quality=%s MaxATR=%s",
                        InpSignalExpiry > 0 ? StringFormat("%dbars", InpSignalExpiry) : "inf",
                        InpPullbackQuality ? "ON" : "OFF",
                        InpEntryHLATR_Max > 0.0 ? StringFormat("%.1f", InpEntryHLATR_Max) : "inf");
      string camInfo = InpCamarillaEnable
         ? StringFormat("CamarillaZone(near=%.1fATR RSI<=%.0f/>=%.0f TP=%s)",
                        InpCamNearATR, InpC2_RSI_Buy, InpC2_RSI_Sell, InpCamZoneTP?"Zone":"ATR")
         : "OFF";
      string lockInfo = InpMagicConflictCheck ? (g_lockAcquired ? "ACQ" : "OFF") : "DISABLED";
      string recInfo  = InpReconcileOnInit
         ? StringFormat("Daily=%s CD=%s",
                        g_reconciledDaily    ? "Y" : "n",
                        g_reconciledCooldown ? "Y" : "n")
         : "OFF";
      string c1State = InpEntry1Enable
         ? StringFormat("ON B=%s S=%s", InpEntry1Buy?"Y":"n", InpEntry1Sell?"Y":"n")
         : "OFF";
      string c2State = InpEntry2Enable
         ? StringFormat("ON B=%s S=%s", InpEntry2Buy?"Y":"n", InpEntry2Sell?"Y":"n")
         : "OFF";

      PrintFormat("KOGANE_gold_EA v2.0 Init | EntryTF=%s | %s | %s | SL/TP=%s |"
                  " Cond1[%s ATR%d BB%d/%.1f %s] Cond2[%s ATR%d BB%d/%.1f+%.1f %s] |"
                  " D1=%s | TF=%s | CD=%s | DailyLoss=%s | Time=%s | Spread=%s |"
                  " Lock=%s | Reconcile=%s |"
                  " Symbol=%s | AccCcy=%s ProfitCcy=%s",
                  entryTfInfo, lotMode, tpMode, sltpSrc,
                  c1State,
                  InpATR1_Period, InpBB1_Period, InpBB1_Deviation, c1Info,
                  c2State,
                  InpATR2_Period, InpBB2_Period, InpBB2_Deviation, InpBB2_Dev1, camInfo,
                  d1Filt, tfFilt, cdInfo, dlInfo, tmInfo, spInfo,
                  lockInfo, recInfo,
                  _Symbol, accountCcy, profitCcy);
   }

   return INIT_SUCCEEDED;
}

//==================================================================
//  OnDeinit
//==================================================================
void OnDeinit(const int reason)
{
   //--- Release multi-instance lock first.
   //    Always release on deinit; if this is a recompile/parameter-change
   //    cycle, the next OnInit will re-acquire instantly. The 60-sec stale
   //    threshold protects against the brief gap.
   ReleaseMagicLock();

   if(g_hATR1 != INVALID_HANDLE) { IndicatorRelease(g_hATR1); g_hATR1 = INVALID_HANDLE; }
   if(g_hBB1  != INVALID_HANDLE) { IndicatorRelease(g_hBB1);  g_hBB1  = INVALID_HANDLE; }
   if(g_hRSI  != INVALID_HANDLE) { IndicatorRelease(g_hRSI);  g_hRSI  = INVALID_HANDLE; }
   if(g_hATR2 != INVALID_HANDLE) { IndicatorRelease(g_hATR2); g_hATR2 = INVALID_HANDLE; }
   if(g_hBB2  != INVALID_HANDLE) { IndicatorRelease(g_hBB2);  g_hBB2  = INVALID_HANDLE; }
   if(g_hBB2s != INVALID_HANDLE) { IndicatorRelease(g_hBB2s); g_hBB2s = INVALID_HANDLE; }
   if(g_hMA   != INVALID_HANDLE) { IndicatorRelease(g_hMA);   g_hMA   = INVALID_HANDLE; }
   if(g_hTF_EMA != INVALID_HANDLE) { IndicatorRelease(g_hTF_EMA); g_hTF_EMA = INVALID_HANDLE; }
   if(g_hH1_ATR != INVALID_HANDLE) { IndicatorRelease(g_hH1_ATR); g_hH1_ATR = INVALID_HANDLE; }
   DeletePanel();
}

//==================================================================
//  OnTradeTransaction — clean up trail counter on position close
//------------------------------------------------------------------
//  Listens for DEAL_ADD events and removes the per-position
//  trailing-update counter GV the moment a position is fully closed
//  (DEAL_ENTRY_OUT) or reversed (DEAL_ENTRY_INOUT). The OnInit
//  orphan sweep covers any event we miss (e.g. EA offline at close).
//
//  Filters: same-symbol + same-magic only — leaves other instances'
//  GVs alone.
//==================================================================
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(dealTicket == 0) return;

   // Pull the deal from history to inspect entry direction & magic.
   if(!HistoryDealSelect(dealTicket)) return;

   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)            return;
   if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNumber) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;

   ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(posId == 0) return;

   string keyCnt = TrailCntKey(posId);
   string keyExt = TrailExtKey(posId);
   bool delCnt = false, delExt = false;
   if(GlobalVariableCheck(keyCnt)) { GlobalVariableDel(keyCnt); delCnt = true; }
   if(GlobalVariableCheck(keyExt)) { GlobalVariableDel(keyExt); delExt = true; }

   if(InpPrintLog && (delCnt || delExt))
      PrintFormat("[TrailCnt] Deleted on close: pos=%I64u entry=%d cnt=%s ext=%s",
                  posId, (int)entry,
                  delCnt ? "Y" : "n", delExt ? "Y" : "n");
}

//==================================================================
//  OnTester — custom optimization criterion
//------------------------------------------------------------------
//  Returns a single double value the Strategy Tester uses to rank
//  optimization passes. Hard filters return -DBL_MAX so failing
//  passes are pushed to the bottom of the optimization table.
//
//  Modes:
//   TESTER_DEFAULT       : Profit Factor (simple, broker-friendly)
//   TESTER_RECOVERY      : NetProfit / MaxBalanceDD     (capital efficiency)
//   TESTER_SHARPE        : Sharpe Ratio                 (risk-adjusted return)
//   TESTER_COMPOSITE     : Profit x min(PF,3) x sqrt(N) x (1 - DD%/50)
//                          (recommended default — penalizes both low trade
//                           counts and excessive drawdown simultaneously)
//   TESTER_RISK_ADJUSTED : NetProfit / DD%   (gated by min trade count)
//
//  Hard filters (any failure -> -DBL_MAX):
//   - Min trades
//   - Max DD%
//   - Min net profit
//   - Both directions traded
//   - Per-side trade ratio cap (overfitting guard)
//==================================================================
double OnTester()
{
   // --- Read all relevant tester statistics ---
   double netProfit  = TesterStatistics(STAT_PROFIT);
   double pf         = TesterStatistics(STAT_PROFIT_FACTOR);
   double recovery   = TesterStatistics(STAT_RECOVERY_FACTOR);
   double sharpe     = TesterStatistics(STAT_SHARPE_RATIO);
   double expPayoff  = TesterStatistics(STAT_EXPECTED_PAYOFF);
   double trades     = TesterStatistics(STAT_TRADES);
   double longTrades = TesterStatistics(STAT_LONG_TRADES);
   double shortTrades= TesterStatistics(STAT_SHORT_TRADES);
   double profitTr   = TesterStatistics(STAT_PROFIT_TRADES);
   double lossTr     = TesterStatistics(STAT_LOSS_TRADES);
   double balanceDD  = TesterStatistics(STAT_BALANCE_DD);
   double balanceDDp = TesterStatistics(STAT_BALANCE_DDREL_PERCENT);
   double equityDDp  = TesterStatistics(STAT_EQUITYDD_PERCENT);
   double equityDDmaxP = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double conLossMax = TesterStatistics(STAT_MAX_CONLOSSES);   // count of max consecutive losses
   double conWinMax  = TesterStatistics(STAT_MAX_CONWINS);     // count of max consecutive wins

   // Use the worse of balance-DD% / equity-DD% as the effective DD
   double effDDpct = MathMax(balanceDDp, equityDDmaxP);
   if(effDDpct <= 0.0) effDDpct = equityDDp;  // fallback

   // Win rate (defensive against div-by-zero)
   double totalClosed = profitTr + lossTr;
   double winRate = (totalClosed > 0.0) ? (profitTr / totalClosed) : 0.0;

   // --- Hard filters -----------------------------------------------
   string rejectReason = "";

   if(trades < (double)InpTesterMinTrades)
      rejectReason = StringFormat("trades=%.0f<%d", trades, InpTesterMinTrades);

   else if(InpTesterMaxDDPercent > 0.0 && effDDpct > InpTesterMaxDDPercent)
      rejectReason = StringFormat("DD%%=%.2f>%.1f", effDDpct, InpTesterMaxDDPercent);

   else if(netProfit < InpTesterMinProfit)
      rejectReason = StringFormat("profit=%.2f<%.2f", netProfit, InpTesterMinProfit);

   else if(InpTesterRequireBothSides && (longTrades < 1.0 || shortTrades < 1.0))
      rejectReason = StringFormat("one-sided (long=%.0f short=%.0f)", longTrades, shortTrades);

   else if(InpTesterMaxSideRatio > 0.0 && trades > 0.0)
   {
      double maxSide = MathMax(longTrades, shortTrades);
      double sideRatio = maxSide / trades;
      if(sideRatio > InpTesterMaxSideRatio)
         rejectReason = StringFormat("side ratio=%.2f>%.2f", sideRatio, InpTesterMaxSideRatio);
   }

   if(rejectReason != "")
   {
      if(InpTesterPrintReport)
         PrintFormat("[OnTester REJECT] %s | profit=%.2f trades=%.0f DD%%=%.2f PF=%.2f",
                     rejectReason, netProfit, trades, effDDpct, pf);
      return -DBL_MAX;
   }

   // --- Score by mode ----------------------------------------------
   double score = 0.0;
   string modeName = "";

   switch(InpTesterMode)
   {
      case TESTER_DEFAULT:
         score = pf;
         modeName = "ProfitFactor";
         break;

      case TESTER_RECOVERY:
         score = recovery;
         modeName = "RecoveryFactor";
         break;

      case TESTER_SHARPE:
         score = sharpe;
         modeName = "Sharpe";
         break;

      case TESTER_RISK_ADJUSTED:
         // NetProfit per 1% of DD (gated above by min trades)
         if(effDDpct > 0.0) score = netProfit / effDDpct;
         else               score = netProfit;  // no DD = perfect (but rare)
         modeName = "RiskAdjusted(P/DD%)";
         break;

      case TESTER_COMPOSITE:
      default:
      {
         // Composite: rewards consistency, penalizes thin samples and big DD
         //   netProfit            — primary driver
         //   min(PF, 3.0)         — cap to prevent extreme values from few trades dominating
         //   sqrt(trades / 100)   — diminishing returns on trade count, gates thin samples
         //   (1 - DD%/50)         — DD penalty: 0% DD => 1.0,  50% DD => 0.0
         double pfCapped   = MathMin(pf, 3.0);
         double tradeBoost = MathSqrt(trades / 100.0);
         double ddPenalty  = MathMax(0.0, 1.0 - effDDpct / 50.0);

         score = netProfit * pfCapped * tradeBoost * ddPenalty;

         // If profit is negative, score should also be negative (safeguard)
         if(netProfit <= 0.0) score = netProfit;

         modeName = StringFormat("Composite (PF=%.2f trd_boost=%.2f dd_pen=%.2f)",
                                  pfCapped, tradeBoost, ddPenalty);
         break;
      }
   }

   // --- Detailed report --------------------------------------------
   if(InpTesterPrintReport)
   {
      PrintFormat("[OnTester PASS] mode=%s score=%.4f", modeName, score);
      PrintFormat("  Profit=%.2f  PF=%.3f  Recovery=%.3f  Sharpe=%.3f  ExpPayoff=%.3f",
                  netProfit, pf, recovery, sharpe, expPayoff);
      PrintFormat("  Trades=%.0f (L=%.0f S=%.0f)  WinRate=%.1f%%  ConWin=%.0f ConLoss=%.0f",
                  trades, longTrades, shortTrades, winRate * 100.0, conWinMax, conLossMax);
      PrintFormat("  DD: balance=%.2f (%.2f%%)  equity_max=%.2f%%  effective=%.2f%%",
                  balanceDD, balanceDDp, equityDDmaxP, effDDpct);
   }

   return score;
}

//==================================================================
//  Position check by condition
//==================================================================
bool HasPosComment(const string comment)
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString (POSITION_SYMBOL)  != _Symbol)        continue;
      if(PositionGetInteger(POSITION_MAGIC)   != InpMagicNumber) continue;
      if(PositionGetString (POSITION_COMMENT) == comment)        return true;
   }
   return false;
}
bool HasPosCond1() { return HasPosComment(COMMENT_COND1_BUY) || HasPosComment(COMMENT_COND1_SELL); }
bool HasPosCond2() { return HasPosComment(COMMENT_COND2_BUY) || HasPosComment(COMMENT_COND2_SELL); }

//==================================================================
//  Stops level / Freeze level helpers
//------------------------------------------------------------------
//  STOPS_LEVEL  : Minimum distance from current price for placing
//                 (or modifying) SL / TP. Below this -> INVALID_STOPS.
//  FREEZE_LEVEL : Range around current price where an order/position
//                 cannot be modified or closed. Different concept!
//------------------------------------------------------------------
//==================================================================

// Pure stops-level distance + user buffer + spread fallback (for placement)
double GetStopsLevelDist()
{
   long pts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double dist = (double)pts * _Point;

   // Many ECN/STP brokers report 0 (dynamic). Use spread*multi as a guard.
   if(InpStopsUseSpreadFallback && pts == 0)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double spreadDist = (double)spread * _Point * InpStopsSpreadMulti;
      if(spreadDist > dist) dist = spreadDist;
   }

   // User-defined buffer (recommended >=5 for Gold)
   dist += (double)MathMax(0, InpStopsBufferPoints) * _Point;

   if(dist <= 0.0) dist = _Point; // never zero
   return dist;
}

// Pure freeze-level distance (for modify/close blocking decisions)
double GetFreezeLevelDist()
{
   long pts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)pts * _Point;
}

// Adjust SL/TP for buy entry to satisfy stops level. Returns false if invalid.
bool AdjustBuyStops(const double ask, double &sl, double &tp)
{
   double minDist = GetStopsLevelDist();
   if(sl > 0.0 && (ask - sl) < minDist) sl = NormalizeDouble(ask - minDist, _Digits);
   if(tp > 0.0 && (tp - ask) < minDist) tp = NormalizeDouble(ask + minDist, _Digits);
   if(sl > 0.0 && sl >= ask) return false;
   if(tp > 0.0 && tp <= ask) return false;
   return true;
}

// Adjust SL/TP for sell entry to satisfy stops level. Returns false if invalid.
bool AdjustSellStops(const double bid, double &sl, double &tp)
{
   double minDist = GetStopsLevelDist();
   if(sl > 0.0 && (sl - bid) < minDist) sl = NormalizeDouble(bid + minDist, _Digits);
   if(tp > 0.0 && (bid - tp) < minDist) tp = NormalizeDouble(bid - minDist, _Digits);
   if(sl > 0.0 && sl <= bid) return false;
   if(tp > 0.0 && tp >= bid) return false;
   return true;
}

// Check if a specific position is currently in the freeze zone
// (broker forbids modify/close while inside this range).
bool IsPositionFrozen(const ENUM_POSITION_TYPE pt,
                      const double psl, const double ptp,
                      const double curBid, const double curAsk)
{
   double frz = GetFreezeLevelDist();
   if(frz <= 0.0) return false;

   if(pt == POSITION_TYPE_BUY)
   {
      if(psl > 0.0 && MathAbs(curBid - psl) < frz) return true;
      if(ptp > 0.0 && MathAbs(ptp - curBid) < frz) return true;
   }
   else
   {
      if(psl > 0.0 && MathAbs(psl - curAsk) < frz) return true;
      if(ptp > 0.0 && MathAbs(curAsk - ptp) < frz) return true;
   }
   return false;
}

// Returns true if any open position belonging to this EA is within
// FREEZE_LEVEL of its SL or TP. Used as a soft entry guard so we do
// not stack entries on top of a position that is about to be closed
// by the broker. (Hedging accounts: this is purely advisory.)
bool AnyPositionLocked()
{
   double frz = GetFreezeLevelDist();
   if(frz <= 0.0) return false;

   double curBid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double curAsk  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString (POSITION_SYMBOL) != _Symbol)        continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagicNumber) continue;

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double psl = PositionGetDouble(POSITION_SL);
      double ptp = PositionGetDouble(POSITION_TP);
      if(IsPositionFrozen(pt, psl, ptp, curBid, curAsk)) return true;
   }
   return false;
}

// Classify a trade retcode as "retryable on next tick" (transient).
bool IsRetryableRetcode(const uint rc)
{
   switch(rc)
   {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_REJECT:
      case TRADE_RETCODE_ERROR:
      case TRADE_RETCODE_TIMEOUT:
      case TRADE_RETCODE_CONNECTION:
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
         return true;
   }
   return false;
}

//==================================================================
//  Buy/Sell with INVALID_STOPS retry
//------------------------------------------------------------------
//  If the broker rejects the order with INVALID_STOPS we widen
//  SL/TP by an extra stops-level distance and retry up to
//  InpInvalidStopsRetry times. Other failures are NOT retried here
//  (transient errors are handled by the next bar's signal cycle —
//   retrying with a stale price is more dangerous than waiting).
//==================================================================
bool TryBuyWithRetry(const double lot, const double ask,
                     double sl, double tp, const string comment)
{
   int maxAttempts = 1 + MathMax(0, InpInvalidStopsRetry);
   for(int attempt = 1; attempt <= maxAttempts; attempt++)
   {
      double askNow = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      // Re-validate against latest price each retry
      double slUse = sl, tpUse = tp;
      if(!AdjustBuyStops(askNow, slUse, tpUse))
      {
         PrintFormat("[Buy Retry %d] Stops invalid after re-adjust, abort", attempt);
         return false;
      }

      if(g_trade.Buy(lot, _Symbol, askNow, slUse, tpUse, comment))
      {
         if(attempt > 1 && InpPrintLog)
            PrintFormat("[Buy Retry SUCCESS] attempt=%d SL=%.5f TP=%.5f", attempt, slUse, tpUse);
         return true;
      }

      uint rc = g_trade.ResultRetcode();
      if(rc == TRADE_RETCODE_INVALID_STOPS && attempt < maxAttempts)
      {
         // Widen SL/TP by an additional stops-level distance and retry
         double extra = GetStopsLevelDist();
         if(sl > 0.0) sl = NormalizeDouble(sl - extra, _Digits);
         if(tp > 0.0) tp = NormalizeDouble(tp + extra, _Digits);
         PrintFormat("[Buy Retry %d/%d] INVALID_STOPS - widening SL/TP by %.0fpt",
                     attempt, maxAttempts, extra / _Point);
         continue;
      }

      // Non-retryable or out of attempts
      PrintFormat("[Buy Failed] RetCode=%d %s (attempt %d/%d)",
                  rc, g_trade.ResultRetcodeDescription(), attempt, maxAttempts);
      return false;
   }
   return false;
}

bool TrySellWithRetry(const double lot, const double bid,
                      double sl, double tp, const string comment)
{
   int maxAttempts = 1 + MathMax(0, InpInvalidStopsRetry);
   for(int attempt = 1; attempt <= maxAttempts; attempt++)
   {
      double bidNow = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double slUse = sl, tpUse = tp;
      if(!AdjustSellStops(bidNow, slUse, tpUse))
      {
         PrintFormat("[Sell Retry %d] Stops invalid after re-adjust, abort", attempt);
         return false;
      }

      if(g_trade.Sell(lot, _Symbol, bidNow, slUse, tpUse, comment))
      {
         if(attempt > 1 && InpPrintLog)
            PrintFormat("[Sell Retry SUCCESS] attempt=%d SL=%.5f TP=%.5f", attempt, slUse, tpUse);
         return true;
      }

      uint rc = g_trade.ResultRetcode();
      if(rc == TRADE_RETCODE_INVALID_STOPS && attempt < maxAttempts)
      {
         double extra = GetStopsLevelDist();
         if(sl > 0.0) sl = NormalizeDouble(sl + extra, _Digits);
         if(tp > 0.0) tp = NormalizeDouble(tp - extra, _Digits);
         PrintFormat("[Sell Retry %d/%d] INVALID_STOPS - widening SL/TP by %.0fpt",
                     attempt, maxAttempts, extra / _Point);
         continue;
      }

      PrintFormat("[Sell Failed] RetCode=%d %s (attempt %d/%d)",
                  rc, g_trade.ResultRetcodeDescription(), attempt, maxAttempts);
      return false;
   }
   return false;
}

//==================================================================
//  Cooldown: detect if last close was a stop-loss
//==================================================================
void CheckCooldownTrigger()
{
   if(!InpCooldownEnable) return;

   datetime from = TimeCurrent() - 3600;
   datetime to   = TimeCurrent();
   if(!HistorySelect(from, to)) return;

   int totalDeals = HistoryDealsTotal();
   if(totalDeals == 0) return;

   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC)  != InpMagicNumber) continue;
      if(HistoryDealGetString (dealTicket, DEAL_SYMBOL) != _Symbol)        continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                    + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                    + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);

      if(dealTime <= g_cooldownUntil - InpCooldownMinutes * 60) break;

      if(profit < 0.0)
      {
         g_cooldownUntil = dealTime + InpCooldownMinutes * 60;
         if(InpPrintLog)
            PrintFormat("[Cooldown Triggered] Loss=%.2f Until=%s",
                        profit, TimeToString(g_cooldownUntil, TIME_DATE | TIME_MINUTES));
      }
      break;
   }
}

bool IsCooldownActive()
{
   if(!InpCooldownEnable) return false;
   return (TimeCurrent() < g_cooldownUntil);
}

//==================================================================
//  Daily loss limit
//==================================================================
void UpdateDailyPnL()
{
   if(!InpDailyLossEnable) return;

   MqlDateTime dtNow;
   TimeCurrent(dtNow);
   datetime today = (datetime)(TimeCurrent() - dtNow.hour*3600 - dtNow.min*60 - dtNow.sec);

   if(today != g_dailyLossDate)
   {
      // New day: reset
      g_dailyLossDate     = today;
      g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyPnL          = 0.0;
      g_dailyLossLocked   = false;
      if(InpPrintLog)
         PrintFormat("[Daily Reset] Date=%s Balance=%.2f",
                     TimeToString(today, TIME_DATE), g_dailyStartBalance);
      return;
   }

   if(g_dailyLossLocked) return;

   datetime dayStart = today;
   datetime dayEnd   = TimeCurrent();
   if(!HistorySelect(dayStart, dayEnd)) return;

   double totalPnL = 0.0;
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC)  != InpMagicNumber) continue;
      if(HistoryDealGetString (dealTicket, DEAL_SYMBOL) != _Symbol)        continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      totalPnL += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   }

   g_dailyPnL = totalPnL;

   if(g_dailyStartBalance > 0.0)
   {
      double lossPct = -g_dailyPnL / g_dailyStartBalance * 100.0;
      if(lossPct >= InpDailyLossMaxPct)
      {
         g_dailyLossLocked = true;
         if(InpPrintLog)
            PrintFormat("[Daily Loss Limit Reached] PnL=%.2f (%.2f%%) Balance=%.2f -> Entry stopped",
                        g_dailyPnL, -lossPct, g_dailyStartBalance);

         if(InpDailyLossCloseAll)
            CloseAllPositions();
      }
   }
}

bool IsDailyLossLocked()
{
   if(!InpDailyLossEnable) return false;
   return g_dailyLossLocked;
}

// Returns true if all positions belonging to this EA were successfully closed.
// If any were frozen or rejected with a retryable retcode, sets g_pendingForceClose
// so OnTick can retry. Caller can poll g_pendingForceClose to know if work remains.
bool CloseAllPositions()
{
   double curBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double curAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool   allDone = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_posInfo.SelectByIndex(i)) continue;
      if(g_posInfo.Symbol() != _Symbol)        continue;
      if(g_posInfo.Magic()  != InpMagicNumber) continue;
      ulong  ticket  = g_posInfo.Ticket();
      ENUM_POSITION_TYPE pt = g_posInfo.PositionType();
      double psl = g_posInfo.StopLoss();
      double ptp = g_posInfo.TakeProfit();

      // Skip if frozen — broker will reject the close. Will retry on next call.
      if(IsPositionFrozen(pt, psl, ptp, curBid, curAsk))
      {
         if(InpPrintLog) PrintFormat("[Force Close - Frozen, skipped] Ticket=%d (will retry)", ticket);
         allDone = false;
         continue;
      }

      if(g_trade.PositionClose(ticket))
      { if(InpPrintLog) PrintFormat("[Force Close - Daily Limit] Ticket=%d", ticket); }
      else
      {
         uint rc = g_trade.ResultRetcode();
         bool retryable = IsRetryableRetcode(rc);
         PrintFormat("[Force Close Failed] Ticket=%d RetCode=%d %s%s",
                     ticket, rc, g_trade.ResultRetcodeDescription(),
                     retryable ? " (will retry next tick)" : "");
         if(retryable) allDone = false;
      }
   }

   g_pendingForceClose = !allDone;
   return allDone;
}

//==================================================================
//  Trading hours filter (per condition, 3 sessions each, OR-combined)
//------------------------------------------------------------------
//  Returns true if ANY enabled session of the given set contains the
//  current hour. If the master is enabled but the set has no active
//  session, returns false (that condition does not trade on time
//  grounds). Master OFF => always true.
//==================================================================
bool IsInSessionWindow(const int hour, const int startH, const int endH)
{
   // Same-hour boundary is treated as an empty/disabled window
   // (a zero-width window can never contain "the current hour").
   if(startH == endH) return false;
   if(startH <  endH) return (hour >= startH && hour <  endH);
   // Day-wrap (e.g. 22..3): allow last-evening hours OR early-morning hours.
   return (hour >= startH || hour < endH);
}

// Generic evaluator for one condition's session set.
bool IsWithinSessions(const bool aEn, const int aS, const int aE,
                      const bool eEn, const int eS, const int eE,
                      const bool uEn, const int uS, const int uE)
{
   if(!InpTimeFilterEnable) return true;

   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;

   if(aEn && IsInSessionWindow(hour, aS, aE)) return true;
   if(eEn && IsInSessionWindow(hour, eS, eE)) return true;
   if(uEn && IsInSessionWindow(hour, uS, uE)) return true;
   return false;
}

bool IsWithinTradingHours1()
{
   return IsWithinSessions(InpTime1AsiaEnable,    InpTime1AsiaStart,    InpTime1AsiaEnd,
                           InpTime1EuropeEnable,  InpTime1EuropeStart,  InpTime1EuropeEnd,
                           InpTime1AmericaEnable, InpTime1AmericaStart, InpTime1AmericaEnd);
}

bool IsWithinTradingHours2()
{
   return IsWithinSessions(InpTime2AsiaEnable,    InpTime2AsiaStart,    InpTime2AsiaEnd,
                           InpTime2EuropeEnable,  InpTime2EuropeStart,  InpTime2EuropeEnd,
                           InpTime2AmericaEnable, InpTime2AmericaStart, InpTime2AmericaEnd);
}

// Compact "[A:s-e E:s-e U:s-e]" string for one session set (logging).
string SessionSetStr(const bool aEn, const int aS, const int aE,
                     const bool eEn, const int eS, const int eE,
                     const bool uEn, const int uS, const int uE)
{
   string a = aEn ? StringFormat("A:%d-%d", aS, aE) : "A:OFF";
   string e = eEn ? StringFormat("E:%d-%d", eS, eE) : "E:OFF";
   string u = uEn ? StringFormat("U:%d-%d", uS, uE) : "U:OFF";
   return "[" + a + " " + e + " " + u + "]";
}

//==================================================================
//  Spread filter
//==================================================================
bool IsSpreadAcceptable()
{
   if(!InpSpreadFilterEnable) return true;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= InpMaxSpreadPoints);
}

//==================================================================
//  D1 direction filter
//  +1 = BUY allowed (Bid above D1 bar0 open)
//  -1 = SELL allowed (Bid below D1 bar0 open)
//   0 = filter OFF, or exactly at open
//------------------------------------------------------------------
//  Uses the still-forming current daily candle's OPEN vs live Bid.
//==================================================================
int GetD1Direction()
{
   if(!InpD1FilterEnable) return 0;

   double d1Open[];
   ArraySetAsSeries(d1Open, true);
   if(CopyOpen(_Symbol, PERIOD_D1, 0, 1, d1Open) < 1) return 0;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid > d1Open[0]) return +1;
   if(bid < d1Open[0]) return -1;
   return 0;
}

//==================================================================
//  Higher-TF EMA filter
//  +1 = BUY allowed  : EMA[bar2] < EMA[bar1] (rising)  AND  bar1 bullish
//  -1 = SELL allowed : EMA[bar2] > EMA[bar1] (falling) AND  bar1 bearish
//   0 = filter OFF, or no directional confirmation
//------------------------------------------------------------------
//  bar1 = last CLOSED bar of InpTF_Period, bar2 = the bar before it.
//  Candle direction uses the closed bar1 (Close[1] vs Open[1]) so it
//  is stable for the whole InpTF_Period bar (not the forming bar0).
//==================================================================
int GetTFFilterDirection()
{
   if(!InpTFFilterEnable) return 0;

   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(g_hTF_EMA, 0, 0, 3, ema) < 3) return 0;

   double tfOpen[], tfClose[];
   ArraySetAsSeries(tfOpen,  true);
   ArraySetAsSeries(tfClose, true);
   if(CopyOpen (_Symbol, InpTF_Period, 0, 3, tfOpen)  < 3) return 0;
   if(CopyClose(_Symbol, InpTF_Period, 0, 3, tfClose) < 3) return 0;

   bool bar1Bull = (tfClose[1] > tfOpen[1]);
   bool bar1Bear = (tfClose[1] < tfOpen[1]);

   // BUY: EMA rising AND last closed bar bullish
   if(ema[2] < ema[1] && bar1Bull) return +1;
   // SELL: EMA falling AND last closed bar bearish
   if(ema[2] > ema[1] && bar1Bear) return -1;
   return 0;
}

//==================================================================
//  SL/TP ATR source (M1 or H1)
//==================================================================
double GetSLTP_ATR()
{
   if(InpSLTP_ATRSource == SLTP_ATR_H1)
   {
      double h1Atr[];
      ArraySetAsSeries(h1Atr, true);
      if(CopyBuffer(g_hH1_ATR, 0, 0, 3, h1Atr) < 3) return 0.0;
      return h1Atr[1];
   }
   return 0.0;
}

//==================================================================
//  Camarilla pivot calculation (previous D1 OHLC)
//  Recalculated once per day
//==================================================================
void UpdateCamarillaPivots()
{
   if(!InpCamarillaEnable) return;

   datetime d1Time = iTime(_Symbol, PERIOD_D1, 0);
   if(d1Time == 0 || d1Time == g_camarillaDate) return;
   g_camarillaDate = d1Time;

   double d1Hi[], d1Lo[], d1Cl[];
   ArraySetAsSeries(d1Hi, true);
   ArraySetAsSeries(d1Lo, true);
   ArraySetAsSeries(d1Cl, true);
   if(CopyHigh (_Symbol, PERIOD_D1, 0, 3, d1Hi) < 3) return;
   if(CopyLow  (_Symbol, PERIOD_D1, 0, 3, d1Lo) < 3) return;
   if(CopyClose(_Symbol, PERIOD_D1, 0, 3, d1Cl) < 3) return;

   double pH = d1Hi[1];
   double pL = d1Lo[1];
   double pC = d1Cl[1];
   double range = pH - pL;

   if(range <= 0.0) return;

   g_camPivot = (pH + pL + pC) / 3.0;
   g_camR1    = pC + range * 1.1 / 12.0;
   g_camS1    = pC - range * 1.1 / 12.0;
   g_camR2    = pC + range * 1.1 / 6.0;
   g_camS2    = pC - range * 1.1 / 6.0;
   g_camR3    = pC + range * 1.1 / 4.0;
   g_camS3    = pC - range * 1.1 / 4.0;
   g_camR4    = pC + range * 1.1 / 2.0;
   g_camS4    = pC - range * 1.1 / 2.0;
   g_camR5    = (pH / pL) * pC;
   g_camS5    = pC - (g_camR5 - pC);

   if(InpPrintLog)
      PrintFormat("[Camarilla Updated] PrevH=%.2f L=%.2f C=%.2f Range=%.2f | "
                  "R5=%.2f R4=%.2f R3=%.2f R2=%.2f R1=%.2f P=%.2f "
                  "S1=%.2f S2=%.2f S3=%.2f S4=%.2f S5=%.2f",
                  pH, pL, pC, range,
                  g_camR5, g_camR4, g_camR3, g_camR2, g_camR1, g_camPivot,
                  g_camS1, g_camS2, g_camS3, g_camS4, g_camS5);
}

//==================================================================
//  Panel UI
//==================================================================
void PanelCreateLabel(const string name, int x, int y, string text,
                      color clr = clrWhite, int fontSize = 9)
{
   string objName = PANEL_PREFIX + name;
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_ANCHOR,    ANCHOR_LEFT_UPPER);
      ObjectSetString (0, objName, OBJPROP_FONT,      "Arial");
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE,  fontSize);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN,     true);
   }
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
   ObjectSetString (0, objName, OBJPROP_TEXT,       text);
   ObjectSetInteger(0, objName, OBJPROP_COLOR,      clr);
}

void PanelCreateBG(const string name, int x, int y, int w, int h)
{
   string objName = PANEL_PREFIX + name;
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN,     true);
   }
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE,       w);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE,       h);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR,     C'20,20,30');
   ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR,C'60,60,80');
   ObjectSetInteger(0, objName, OBJPROP_BACK,        false);
}

string GetCurrentZoneName()
{
   if(g_camS4 <= 0.0) return "--";
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price >= g_camR4)      return "R4+(BRK)";
   if(price >= g_camR3)      return "R3-R4";
   if(price >= g_camR2)      return "R2-R3";
   if(price >= g_camR1)      return "R1-R2";
   if(price >= g_camS1)      return "S1-R1";
   if(price >= g_camS2)      return "S1-S2";
   if(price >= g_camS3)      return "S2-S3";
   if(price >= g_camS4)      return "S3-S4";
   return "S4-(BRK)";
}

void GetPositionInfo(const string commentBuy, const string commentSell,
                     string &status, double &pnl)
{
   status = "---";
   pnl = 0.0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString (POSITION_SYMBOL) != _Symbol)        continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagicNumber) continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(comment == commentBuy)
      {
         status = "Buy";
         pnl = PositionGetDouble(POSITION_PROFIT)
             + PositionGetDouble(POSITION_SWAP);
         return;
      }
      if(comment == commentSell)
      {
         status = "Sell";
         pnl = PositionGetDouble(POSITION_PROFIT)
             + PositionGetDouble(POSITION_SWAP);
         return;
      }
   }
}

void UpdatePanel()
{
   int px = 10, py = 25;
   int lineH = 18;
   int col1 = px + 8;
   int col2 = px + 130;
   int panelW = 230;
   int panelH = 308;
   int row = 0;

   PanelCreateBG("bg", px, py, panelW, panelH);

   PanelCreateLabel("title", col1, py + 4, "KOGANE Gold EA v2.0", C'100,180,255', 10);
   row = 1;

   //--- Filters ---
   int secY = py + 6 + lineH * row;
   PanelCreateLabel("f_hdr", col1, secY, "-- Filters --", C'80,80,100');
   row++;

   // D1 direction
   string d1Str  = (g_panelD1 > 0) ? "BUY ^" : (g_panelD1 < 0) ? "SELL v" : "-- ";
   color  d1Clr  = (g_panelD1 > 0) ? C'50,220,100' : (g_panelD1 < 0) ? C'255,80,80' : clrGray;
   PanelCreateLabel("f_d1l", col1, py + 6 + lineH * row, "D1 Dir:");
   PanelCreateLabel("f_d1v", col2, py + 6 + lineH * row, d1Str, d1Clr);
   row++;

   // TF EMA filter
   string tfStr  = (g_panelTF > 0) ? "BUY ^" : (g_panelTF < 0) ? "SELL v" : "-- ";
   color  tfClr  = (g_panelTF > 0) ? C'50,220,100' : (g_panelTF < 0) ? C'255,80,80' : clrGray;
   PanelCreateLabel("f_tfl", col1, py + 6 + lineH * row, "TF Filter:");
   PanelCreateLabel("f_tfv", col2, py + 6 + lineH * row, tfStr, tfClr);
   row++;

   // Entry gate
   string gateStr = g_panelGateOk ? "OK" : "NG";
   color  gateClr = g_panelGateOk ? C'50,220,100' : C'255,80,80';
   PanelCreateLabel("f_gtl", col1, py + 6 + lineH * row, "Entry Gate:");
   PanelCreateLabel("f_gtv", col2, py + 6 + lineH * row, gateStr, gateClr);
   row++;

   // Margin
   string mgnStr = g_panelMarginOk ? "OK" : "Insufficient";
   color  mgnClr = g_panelMarginOk ? C'50,220,100' : C'255,80,80';
   PanelCreateLabel("f_mgl", col1, py + 6 + lineH * row, "Margin:");
   PanelCreateLabel("f_mgv", col2, py + 6 + lineH * row, mgnStr, mgnClr);
   row++;

   //--- Signal ---
   PanelCreateLabel("s_hdr", col1, py + 6 + lineH * row, "-- Signal --", C'80,80,100');
   row++;

   string buySigStr = g_buySignal ? "ON" : "OFF";
   color  buySigClr = g_buySignal ? C'50,220,100' : clrGray;
   PanelCreateLabel("s_bl", col1, py + 6 + lineH * row, "Buy Signal:");
   PanelCreateLabel("s_bv", col2, py + 6 + lineH * row, buySigStr, buySigClr);
   row++;

   string selSigStr = g_sellSignal ? "ON" : "OFF";
   color  selSigClr = g_sellSignal ? C'255,80,80' : clrGray;
   PanelCreateLabel("s_sl", col1, py + 6 + lineH * row, "Sell Signal:");
   PanelCreateLabel("s_sv", col2, py + 6 + lineH * row, selSigStr, selSigClr);
   row++;

   // HL-ATR
   string hlStr = StringFormat("%.3f", g_panelHLATR);
   color  hlClr = (g_panelHLATR >= InpHLATR_Signal) ? C'255,200,50' : clrWhite;
   PanelCreateLabel("s_hl", col1, py + 6 + lineH * row, "HL-ATR:");
   PanelCreateLabel("s_hv", col2, py + 6 + lineH * row, hlStr, hlClr);
   row++;

   //--- Camarilla ---
   PanelCreateLabel("c_hdr", col1, py + 6 + lineH * row, "-- Camarilla --", C'80,80,100');
   row++;

   g_panelZone = GetCurrentZoneName();
   color zoneClr = clrWhite;
   if(StringFind(g_panelZone, "BRK") >= 0) zoneClr = C'255,80,80';
   else if(StringFind(g_panelZone, "S1-R1") >= 0) zoneClr = C'50,220,100';
   PanelCreateLabel("c_zl", col1, py + 6 + lineH * row, "Zone:");
   PanelCreateLabel("c_zv", col2, py + 6 + lineH * row, g_panelZone, zoneClr);
   row++;

   //--- Positions ---
   PanelCreateLabel("p_hdr", col1, py + 6 + lineH * row, "-- Positions --", C'80,80,100');
   row++;

   string st1, st3;
   double pnl1, pnl3;
   GetPositionInfo(COMMENT_COND1_BUY, COMMENT_COND1_SELL, st1, pnl1);
   GetPositionInfo(COMMENT_COND2_BUY, COMMENT_COND2_SELL, st3, pnl3);

   // Cond.1
   string p1Str = (st1 == "---") ? "---" : StringFormat("%s  %+.0f", st1, pnl1);
   color  p1Clr = (st1 == "---") ? clrGray : (pnl1 >= 0 ? C'50,220,100' : C'255,80,80');
   PanelCreateLabel("p_1l", col1, py + 6 + lineH * row, "Cond.1:");
   PanelCreateLabel("p_1v", col2, py + 6 + lineH * row, p1Str, p1Clr);
   row++;

   // Cond.2
   string p3Str = (st3 == "---") ? "---" : StringFormat("%s  %+.0f", st3, pnl3);
   color  p3Clr = (st3 == "---") ? clrGray : (pnl3 >= 0 ? C'50,220,100' : C'255,80,80');
   PanelCreateLabel("p_3l", col1, py + 6 + lineH * row, "Cond.2:");
   PanelCreateLabel("p_3v", col2, py + 6 + lineH * row, p3Str, p3Clr);
   row++;

   // Total PnL
   double totalPnl = 0.0;
   if(st1 != "---") totalPnl += pnl1;
   if(st3 != "---") totalPnl += pnl3;
   string totStr = StringFormat("%+.0f", totalPnl);
   color  totClr = (totalPnl >= 0) ? C'50,220,100' : C'255,80,80';
   bool   hasAny = (st1 != "---" || st3 != "---");
   PanelCreateLabel("p_tl", col1, py + 6 + lineH * row, "Total PnL:");
   PanelCreateLabel("p_tv", col2, py + 6 + lineH * row, hasAny ? totStr : "---", hasAny ? totClr : clrGray);

   ChartRedraw(0);
}

void DeletePanel()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, PANEL_PREFIX) == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//==================================================================
//  OnTick
//==================================================================
void OnTick()
{
   //--- Multi-instance lock heartbeat (no-op in tester/optimizer)
   RefreshMagicLock();

   //--- Panel update (every tick)
   //    Skip entirely in tester/optimizer non-visual runs: ObjectCreate/
   //    SetInteger/SetString and ChartRedraw on every tick dominate the
   //    Strategy Tester profile. The panel is read-only for trading logic
   //    (the cached g_panel* fields are recomputed each entry pass from
   //    indicator data, never read back here), so skipping is safe.
   //    Visual mode is preserved for live debugging in the tester.
   if(!MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE))
      UpdatePanel();

   //--- Pending force-close retry (frozen positions from previous CloseAllPositions) ---
   //    Runs every tick (not bar) so positions exit ASAP once the freeze zone is left.
   if(g_pendingForceClose)
   {
      // Throttle: at most once per N bars to avoid spamming the broker.
      if((g_barCount - g_lastForceCloseBar) >= MathMax(1, InpFreezeRetryBars))
      {
         g_lastForceCloseBar = g_barCount;
         if(CloseAllPositions() && InpPrintLog)
            Print("[Force Close Retry] All pending positions closed");
      }
   }

   datetime currentBar = iTime(_Symbol, InpEntryTF, 0);
   if(currentBar == 0 || currentBar == g_lastBarTime) return;
   g_lastBarTime = currentBar;

   g_barCount++;
   if(g_barCount <= InpWarmupBars) return;

   //--- Cooldown / daily loss check ---
   CheckCooldownTrigger();
   UpdateDailyPnL();
   UpdateCamarillaPivots();

   if(BarsCalculated(g_hATR1) < InpATR1_Period + 3) return;
   if(BarsCalculated(g_hBB1)  < InpBB1_Period  + 3) return;
   if(BarsCalculated(g_hRSI)  < InpRSI_Period   + 3) return;
   if(BarsCalculated(g_hATR2) < InpATR2_Period  + 3) return;
   if(BarsCalculated(g_hBB2)  < InpBB2_Period   + 3) return;
   if(BarsCalculated(g_hBB2s) < InpBB2_Period   + 3) return;
   if(BarsCalculated(g_hMA)   < InpMA_Period    + 3) return;

   //------------------------------------------------------------------
   //  Price data
   //------------------------------------------------------------------
   double hi[], lo[], op[], cl[];
   ArraySetAsSeries(hi, true); ArraySetAsSeries(lo, true);
   ArraySetAsSeries(op, true); ArraySetAsSeries(cl, true);
   if(CopyHigh (_Symbol, InpEntryTF, 0, 4, hi) < 4) return;
   if(CopyLow  (_Symbol, InpEntryTF, 0, 4, lo) < 4) return;
   if(CopyOpen (_Symbol, InpEntryTF, 0, 4, op) < 4) return;
   if(CopyClose(_Symbol, InpEntryTF, 0, 4, cl) < 4) return;

   //------------------------------------------------------------------
   //  Cond.1 indicators (ATR1 / BB1 / MA)
   //------------------------------------------------------------------
   double atr1[], bb1Upper[], bb1Lower[], ma[];
   ArraySetAsSeries(atr1, true); ArraySetAsSeries(bb1Upper, true);
   ArraySetAsSeries(bb1Lower, true);
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(g_hATR1, 0, 0, 4, atr1)     < 4) return;
   if(CopyBuffer(g_hBB1,  1, 0, 4, bb1Upper) < 4) return;
   if(CopyBuffer(g_hBB1,  2, 0, 4, bb1Lower) < 4) return;
   if(CopyBuffer(g_hMA,   0, 0, 4, ma)       < 4) return;
   if(atr1[1] <= 0.0 || bb1Upper[1] <= 0.0) return;

   //------------------------------------------------------------------
   //  Cond.2 indicators (ATR2 / BB2 / BB2s / RSI)
   //------------------------------------------------------------------
   double atr2[], bb2Upper[], bb2Lower[], bb2sUpper[], bb2sLower[], rsi[];
   ArraySetAsSeries(atr2, true); ArraySetAsSeries(bb2Upper, true); ArraySetAsSeries(bb2Lower, true);
   ArraySetAsSeries(bb2sUpper, true); ArraySetAsSeries(bb2sLower, true); ArraySetAsSeries(rsi, true);
   if(CopyBuffer(g_hATR2, 0, 0, 4, atr2)      < 4) return;
   if(CopyBuffer(g_hBB2,  1, 0, 4, bb2Upper)  < 4) return;
   if(CopyBuffer(g_hBB2,  2, 0, 4, bb2Lower)  < 4) return;
   if(CopyBuffer(g_hBB2s, 1, 0, 4, bb2sUpper) < 4) return;
   if(CopyBuffer(g_hBB2s, 2, 0, 4, bb2sLower) < 4) return;
   if(CopyBuffer(g_hRSI,  0, 0, 4, rsi)       < 4) return;
   if(atr2[1] <= 0.0) return;

   //------------------------------------------------------------------
   //  Bar1 values
   //------------------------------------------------------------------
   double hlAtr1_1  = (hi[1] - lo[1]) / atr1[1];
   double hlAtr1_2  = (hi[1] - lo[1]) / atr2[1];
   bool   bar1_bull = (cl[1] > op[1]);
   bool   bar1_bear = (cl[1] < op[1]);
   double touchTol  = atr1[1] * InpMA_Touch_Buffer;

   //------------------------------------------------------------------
   //  Higher timeframe data
   //------------------------------------------------------------------
   int    d1Dir      = GetD1Direction();
   int    tfDir      = GetTFFilterDirection();
   double sltpATR_H1 = GetSLTP_ATR();

   //------------------------------------------------------------------
   //  Common filter state
   //  Time is per-condition; spread/cooldown/daily are shared.
   //------------------------------------------------------------------
   bool cooldownActive = IsCooldownActive();
   bool dailyLocked    = IsDailyLossLocked();
   bool spreadOk       = IsSpreadAcceptable();
   bool time1Ok        = IsWithinTradingHours1();
   bool time2Ok        = IsWithinTradingHours2();
   bool gateCommonOk   = spreadOk && !cooldownActive && !dailyLocked;  // shared, no time

   //--- Margin check ---
   bool marginOk = true;
   {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double askNow     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(InpMinLotOverride > 0.0) minLot = MathMax(minLot, InpMinLotOverride);
      double reqMargin  = 0.0;
      if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, minLot, askNow, reqMargin))
         marginOk = (freeMargin >= reqMargin);
      else
         marginOk = (freeMargin > 0.0);
   }

   //--- Panel cache update ---
   //  "Entry Gate" reflects: shared gate OK AND at least one condition
   //  is within its trading hours (i.e. an entry is possible right now).
   g_panelD1       = d1Dir;
   g_panelTF       = tfDir;
   g_panelGateOk   = gateCommonOk && (time1Ok || time2Ok);
   g_panelMarginOk = marginOk;
   g_panelHLATR    = hlAtr1_1;

   if(InpDiagLog)
   {
      string sigState    = StringFormat("BuySig=%s SellSig=%s",
                                        g_buySignal  ? "ON" : "off",
                                        g_sellSignal ? "ON" : "off");
      string filterState = StringFormat("D1=%s TF=%s CD=%s DL=%s(%+.0f) Time1=%s Time2=%s Spread=%s",
                                        d1Dir > 0 ? "BUY" : (d1Dir < 0 ? "SELL" : "--"),
                                        tfDir > 0 ? "BUY" : (tfDir < 0 ? "SELL" : "--"),
                                        cooldownActive ? "WAIT" : "OK",
                                        dailyLocked ? "LOCK" : "OK", g_dailyPnL,
                                        time1Ok ? "OK" : "NG",
                                        time2Ok ? "OK" : "NG",
                                        spreadOk ? "OK" : "NG");
      PrintFormat("[DIAG] %s | HL-ATR1=%.3f HL-ATR2=%.3f | "
                  "Pos[C1=%s C2=%s] | %s | %s",
                  TimeToString(iTime(_Symbol, InpEntryTF, 1)),
                  hlAtr1_1, hlAtr1_2,
                  HasPosCond1()?"Y":"N", HasPosCond2()?"Y":"N",
                  sigState, filterState);
   }

   //==================================================================
   //  1. Trailing stop (always active, ignores filters)
   //==================================================================
   if(InpTrailEnable)
   {
      double trailLow[], trailHigh[];
      ArraySetAsSeries(trailLow,  true);
      ArraySetAsSeries(trailHigh, true);

      bool trailDataOk =
         (CopyLow (_Symbol, InpEntryTF, 1, InpTrailBars, trailLow)  == InpTrailBars) &&
         (CopyHigh(_Symbol, InpEntryTF, 1, InpTrailBars, trailHigh) == InpTrailBars);

      if(trailDataOk)
      {
         double lowest  = NormalizeDouble(trailLow[ArrayMinimum(trailLow,   0, InpTrailBars)], _Digits);
         double highest = NormalizeDouble(trailHigh[ArrayMaximum(trailHigh, 0, InpTrailBars)], _Digits);

         double stopsLevelDist = GetStopsLevelDist();
         double freezeLevelDist = GetFreezeLevelDist();
         double curBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double curAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(!g_posInfo.SelectByIndex(i)) continue;
            if(g_posInfo.Symbol() != _Symbol)        continue;
            if(g_posInfo.Magic()  != InpMagicNumber) continue;

            ENUM_POSITION_TYPE posType    = g_posInfo.PositionType();
            double             curSL      = g_posInfo.StopLoss();
            double             curTP      = g_posInfo.TakeProfit();
            double             entryPrice = g_posInfo.PriceOpen();
            ulong              ticket     = g_posInfo.Ticket();

            // [Trail Phase Dispatch]
            //   Phase 1 (counter < InpTrailMaxCount): 5-bar low/high trail
            //   Phase 2 (counter >= InpTrailMaxCount): peak high/low - ATR x Multi
            //   When InpTrailMaxCount == 0: always Phase 1 (Phase 2 disabled)
            int  trailCnt = TrailCntGet(ticket);
            bool inPhase2 = (InpTrailMaxCount > 0 && trailCnt >= InpTrailMaxCount);

            if(!inPhase2)
            {
               //--------------------------------------------------------
               //  Phase 1: 5-bar low/high trailing (capped at InpTrailMaxCount)
               //--------------------------------------------------------
               if(posType == POSITION_TYPE_BUY)
               {
                  // Skip modify if position is FROZEN (broker forbids modify)
                  if(freezeLevelDist > 0.0)
                  {
                     if(curTP > 0.0 && (curTP - curBid) < freezeLevelDist) continue;
                     if(curSL > 0.0 && (curBid - curSL) < freezeLevelDist) continue;
                  }

                  // New SL must be above current SL, above entry, and >= stopsLevel away from Bid
                  double slLimit = NormalizeDouble(curBid - stopsLevelDist, _Digits);
                  if((lowest > curSL) && (lowest >= entryPrice) && (lowest <= slLimit))
                  {
                     if(g_trade.PositionModify(ticket, lowest, curTP))
                     {
                        int newCnt = trailCnt + 1;
                        if(InpTrailMaxCount > 0) TrailCntSet(ticket, newCnt);
                        if(InpPrintLog)
                           PrintFormat("[Trail Buy SL Updated] Ticket=%d SL:%.5f->%.5f Count=%d/%s",
                                       ticket, curSL, lowest, newCnt,
                                       InpTrailMaxCount > 0 ? IntegerToString(InpTrailMaxCount) : "inf");
                     }
                     else PrintFormat("[Trail Buy SL Failed] Ticket=%d RetCode=%d %s", ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
                  }
               }
               else if(posType == POSITION_TYPE_SELL)
               {
                  // Skip modify if position is FROZEN (broker forbids modify)
                  if(freezeLevelDist > 0.0)
                  {
                     if(curTP > 0.0 && (curAsk - curTP) < freezeLevelDist) continue;
                     if(curSL > 0.0 && (curSL - curAsk) < freezeLevelDist) continue;
                  }

                  // New SL must be below current SL, below entry, and >= stopsLevel away from Ask
                  double slLimit = NormalizeDouble(curAsk + stopsLevelDist, _Digits);
                  if((curSL <= 0.0 || highest < curSL) && (highest <= entryPrice) && (highest >= slLimit))
                  {
                     if(g_trade.PositionModify(ticket, highest, curTP))
                     {
                        int newCnt = trailCnt + 1;
                        if(InpTrailMaxCount > 0) TrailCntSet(ticket, newCnt);
                        if(InpPrintLog)
                           PrintFormat("[Trail Sell SL Updated] Ticket=%d SL:%.5f->%.5f Count=%d/%s",
                                       ticket, curSL, highest, newCnt,
                                       InpTrailMaxCount > 0 ? IntegerToString(InpTrailMaxCount) : "inf");
                     }
                     else PrintFormat("[Trail Sell SL Failed] Ticket=%d RetCode=%d %s", ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
                  }
               }
            }
            else
            {
               //--------------------------------------------------------
               //  Phase 2: Chandelier-style trail
               //    BUY  : SL = trackedMax - ATR(M1) * InpTrailATR_Multi
               //    SELL : SL = trackedMin + ATR(M1) * InpTrailATR_Multi
               //  - Counter is NOT incremented (stays at InpTrailMaxCount).
               //  - SL only moves in the advantageous direction.
               //--------------------------------------------------------
               double atrM1 = atr1[1];
               if(atrM1 <= 0.0) continue;            // bad ATR data, skip this tick
               double atrDist = atrM1 * InpTrailATR_Multi;

               if(posType == POSITION_TYPE_BUY)
               {
                  if(freezeLevelDist > 0.0)
                  {
                     if(curTP > 0.0 && (curTP - curBid) < freezeLevelDist) continue;
                     if(curSL > 0.0 && (curBid - curSL) < freezeLevelDist) continue;
                  }

                  // Update tracked max with the most recent COMPLETED M1 bar high
                  double tracked = TrailExtGet(ticket);
                  if(tracked <= 0.0) tracked = hi[1];      // first time in Phase 2
                  if(hi[1] > tracked) tracked = hi[1];
                  TrailExtSet(ticket, tracked);

                  double candSL = NormalizeDouble(tracked - atrDist, _Digits);
                  double slLimit = NormalizeDouble(curBid - stopsLevelDist, _Digits);

                  // Advantageous direction only: candSL must exceed curSL.
                  if((candSL > curSL) && (candSL <= slLimit))
                  {
                     if(g_trade.PositionModify(ticket, candSL, curTP))
                     {
                        if(InpPrintLog)
                           PrintFormat("[Trail2 Buy SL Updated] Ticket=%d SL:%.5f->%.5f (Peak=%.5f - ATRx%.2f=%.5f)",
                                       ticket, curSL, candSL, tracked, InpTrailATR_Multi, atrDist);
                     }
                     else PrintFormat("[Trail2 Buy SL Failed] Ticket=%d RetCode=%d %s", ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
                  }
               }
               else if(posType == POSITION_TYPE_SELL)
               {
                  if(freezeLevelDist > 0.0)
                  {
                     if(curTP > 0.0 && (curAsk - curTP) < freezeLevelDist) continue;
                     if(curSL > 0.0 && (curSL - curAsk) < freezeLevelDist) continue;
                  }

                  // Update tracked min with the most recent COMPLETED M1 bar low
                  double tracked = TrailExtGet(ticket);
                  if(tracked <= 0.0) tracked = lo[1];      // first time in Phase 2
                  if(lo[1] < tracked) tracked = lo[1];
                  TrailExtSet(ticket, tracked);

                  double candSL = NormalizeDouble(tracked + atrDist, _Digits);
                  double slLimit = NormalizeDouble(curAsk + stopsLevelDist, _Digits);

                  // Advantageous direction only: candSL must be lower than curSL (or curSL absent).
                  if((curSL <= 0.0 || candSL < curSL) && (candSL >= slLimit))
                  {
                     if(g_trade.PositionModify(ticket, candSL, curTP))
                     {
                        if(InpPrintLog)
                           PrintFormat("[Trail2 Sell SL Updated] Ticket=%d SL:%.5f->%.5f (Trough=%.5f + ATRx%.2f=%.5f)",
                                       ticket, curSL, candSL, tracked, InpTrailATR_Multi, atrDist);
                     }
                     else PrintFormat("[Trail2 Sell SL Failed] Ticket=%d RetCode=%d %s", ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
                  }
               }
            }
         }
      }
   }

   //==================================================================
   //  2. HL-ATR exit (always active, ignores filters)
   //==================================================================
   if(InpTP_Mode == TP_HLATR_SIGNAL || InpTP_Mode == TP_BOTH)
   {
      bool exitBuy = (hlAtr1_1 >= InpHLATR_ExitA && bar1_bear)
                   ||(hlAtr1_1 >= InpHLATR_ExitB && bar1_bull);
      bool exitSell= (hlAtr1_1 >= InpHLATR_ExitA && bar1_bull)
                   ||(hlAtr1_1 >= InpHLATR_ExitB && bar1_bear);

      if(exitBuy || exitSell)
      {
         double curBidEx   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double curAskEx   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(!g_posInfo.SelectByIndex(i)) continue;
            if(g_posInfo.Symbol() != _Symbol)        continue;
            if(g_posInfo.Magic()  != InpMagicNumber) continue;

            ENUM_POSITION_TYPE posType = g_posInfo.PositionType();
            ulong  ticket = g_posInfo.Ticket();
            double pSL    = g_posInfo.StopLoss();
            double pTP    = g_posInfo.TakeProfit();

            // Skip if inside freeze zone (broker forbids close/modify there)
            if(IsPositionFrozen(posType, pSL, pTP, curBidEx, curAskEx))
            {
               if(InpDiagLog) PrintFormat("[HLATR Exit Skipped - Frozen] Ticket=%d", ticket);
               continue;
            }

            if(posType == POSITION_TYPE_BUY && exitBuy)
            {
               string reason = (hlAtr1_1 >= InpHLATR_ExitB && bar1_bull)
                  ? StringFormat("CondB(same dir bull HL-ATR1=%.3f>=%.1f)", hlAtr1_1, InpHLATR_ExitB)
                  : StringFormat("CondA(reverse bear HL-ATR1=%.3f>=%.1f)", hlAtr1_1, InpHLATR_ExitA);
               if(g_trade.PositionClose(ticket))
               { if(InpPrintLog) PrintFormat("[HLATR Exit Buy] Ticket=%d %s", ticket, reason); }
               else PrintFormat("[HLATR Exit Buy Failed] Ticket=%d RetCode=%d %s", ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
            }
            else if(posType == POSITION_TYPE_SELL && exitSell)
            {
               string reason = (hlAtr1_1 >= InpHLATR_ExitB && bar1_bear)
                  ? StringFormat("CondB(same dir bear HL-ATR1=%.3f>=%.1f)", hlAtr1_1, InpHLATR_ExitB)
                  : StringFormat("CondA(reverse bull HL-ATR1=%.3f>=%.1f)", hlAtr1_1, InpHLATR_ExitA);
               if(g_trade.PositionClose(ticket))
               { if(InpPrintLog) PrintFormat("[HLATR Exit Sell] Ticket=%d %s", ticket, reason); }
               else PrintFormat("[HLATR Exit Sell Failed] Ticket=%d RetCode=%d %s", ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
            }
         }
      }
   }

   //==================================================================
   //  3. Signal management
   //==================================================================
   bool entryBuySignal  = g_buySignal;
   bool entrySellSignal = g_sellSignal;

   // Signal expiry check
   if(g_buySignal && InpSignalExpiry > 0 && (g_barCount - g_buySignalBar) > InpSignalExpiry)
   {
      g_buySignal = false;
      entryBuySignal = false;
      if(InpPrintLog) PrintFormat("[Buy Signal Expired] %d bars elapsed (limit %d)", g_barCount - g_buySignalBar, InpSignalExpiry);
   }
   if(g_sellSignal && InpSignalExpiry > 0 && (g_barCount - g_sellSignalBar) > InpSignalExpiry)
   {
      g_sellSignal = false;
      entrySellSignal = false;
      if(InpPrintLog) PrintFormat("[Sell Signal Expired] %d bars elapsed (limit %d)", g_barCount - g_sellSignalBar, InpSignalExpiry);
   }

   if(!g_buySignal)
   {
      if(hlAtr1_1 >= InpHLATR_Signal && bar1_bull && cl[1] >= bb1Upper[1])
      {
         g_buySignal = true; g_sellSignal = false;
         g_buySignalBar = g_barCount;
         if(InpPrintLog) PrintFormat("[Buy Signal ON]  HL-ATR1=%.3f Close=%.3f BB1_U=%.3f", hlAtr1_1, cl[1], bb1Upper[1]);
      }
   }
   else if(hlAtr1_1 >= InpHLATR_Cancel && bar1_bear)
   {
      g_buySignal = false;
      if(InpPrintLog) PrintFormat("[Buy Signal OFF] HL-ATR1=%.3f", hlAtr1_1);
   }

   if(!g_sellSignal)
   {
      if(hlAtr1_1 >= InpHLATR_Signal && bar1_bear && cl[1] <= bb1Lower[1])
      {
         g_sellSignal = true; g_buySignal = false;
         g_sellSignalBar = g_barCount;
         if(InpPrintLog) PrintFormat("[Sell Signal ON]  HL-ATR1=%.3f Close=%.3f BB1_L=%.3f", hlAtr1_1, cl[1], bb1Lower[1]);
      }
   }
   else if(hlAtr1_1 >= InpHLATR_Cancel && bar1_bull)
   {
      g_sellSignal = false;
      if(InpPrintLog) PrintFormat("[Sell Signal OFF] HL-ATR1=%.3f", hlAtr1_1);
   }

   //==================================================================
   //  4. Entry evaluation
   //==================================================================
   //--- Shared filter gate (spread / cooldown / daily-loss). Time is
   //    checked per-condition below since Cond.1 and Cond.2 can run on
   //    different hours.
   if(!gateCommonOk)
   {
      if(InpDiagLog)
      {
         string reasons = "";
         if(!spreadOk)      reasons += StringFormat("SpreadHigh(%d) ", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
         if(cooldownActive) reasons += StringFormat("Cooldown(until %s) ", TimeToString(g_cooldownUntil, TIME_MINUTES));
         if(dailyLocked)    reasons += StringFormat("DailyLossLimit(%.2f) ", g_dailyPnL);
         PrintFormat("[Entry Blocked - shared] %s", reasons);
      }
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool   useFixedTP = (InpTP_Mode == TP_ATR_ONLY || InpTP_Mode == TP_BOTH);

   // SL/TP ATR
   double sltp_atr1 = (InpSLTP_ATRSource == SLTP_ATR_H1 && sltpATR_H1 > 0.0) ? sltpATR_H1 : atr1[1];
   double sltp_atr2 = (InpSLTP_ATRSource == SLTP_ATR_H1 && sltpATR_H1 > 0.0) ? sltpATR_H1 : atr2[1];

   // Cond.1 filter direction flags (enabled filter must actively confirm)
   bool d1BuyOk  = !InpD1FilterEnable || (d1Dir > 0);
   bool d1SellOk = !InpD1FilterEnable || (d1Dir < 0);
   bool tfBuyOk  = !InpTFFilterEnable || (tfDir > 0);
   bool tfSellOk = !InpTFFilterEnable || (tfDir < 0);

   //==================================================================
   //  Cond.1 Buy
   //==================================================================
   if(InpEntry1Enable && InpEntry1Buy && time1Ok && (!InpOnlyOnePos || !HasPosCond1())
      && entryBuySignal && lo[1] <= ma[1] + touchTol)
   {
      string blockReason = "";
      if(!d1BuyOk)                                                    blockReason = "D1 dir not BUY";
      else if(!tfBuyOk)                                               blockReason = "TF EMA not BUY";
      else if(InpPullbackQuality && !bar1_bull)                       blockReason = "Pullback quality NG (bearish touch)";
      else if(InpEntryHLATR_Max > 0.0 && hlAtr1_1 >= InpEntryHLATR_Max)
                                                                       blockReason = StringFormat("Entry HL-ATR=%.3f >= %.1f", hlAtr1_1, InpEntryHLATR_Max);

      if(blockReason == "")
      {
         double slDist = sltp_atr1 * InpSL_ATR_Multi;
         double sl  = NormalizeDouble(ask - slDist, _Digits);
         double tp  = useFixedTP ? NormalizeDouble(ask + sltp_atr1 * InpTP_ATR_Multi, _Digits) : 0.0;
         if(!AdjustBuyStops(ask, sl, tp))
         {
            if(InpPrintLog) Print("[Cond1 Buy Skip] Stops level invalid");
         }
         else if(AnyPositionLocked())
         {
            if(InpPrintLog) Print("[Cond1 Buy Skip] Existing position close to TP/SL");
         }
         else
         {
            slDist = ask - sl;
            double lot = CalcLot(slDist, ask, ORDER_TYPE_BUY);
            if(lot <= 0.0) Print("[Cond1 Buy Skip] Lot calc failed");
            else if(TryBuyWithRetry(lot, ask, sl, tp, COMMENT_COND1_BUY))
            {
               if(InpPrintLog) PrintFormat("[Cond1 Buy] Ask=%.3f SL=%.3f TP=%s Lot=%.2f HL-ATR=%.3f D1=%s TF=%s Bars=%d",
                                            ask, sl, useFixedTP ? DoubleToString(tp,_Digits) : "HL-ATR",
                                            lot, hlAtr1_1,
                                            d1Dir>0?"BUY":"--", tfDir>0?"BUY":"--",
                                            g_barCount - g_buySignalBar);
               g_buySignal = false;
            }
         }
      }
      else if(InpPrintLog) PrintFormat("[Cond1 Buy Blocked] %s", blockReason);
   }

   //==================================================================
   //  Cond.1 Sell
   //==================================================================
   if(InpEntry1Enable && InpEntry1Sell && time1Ok && (!InpOnlyOnePos || !HasPosCond1())
      && entrySellSignal && hi[1] >= ma[1] - touchTol)
   {
      string blockReason = "";
      if(!d1SellOk)                                                   blockReason = "D1 dir not SELL";
      else if(!tfSellOk)                                              blockReason = "TF EMA not SELL";
      else if(InpPullbackQuality && !bar1_bear)                       blockReason = "Pullback quality NG (bullish touch)";
      else if(InpEntryHLATR_Max > 0.0 && hlAtr1_1 >= InpEntryHLATR_Max)
                                                                       blockReason = StringFormat("Entry HL-ATR=%.3f >= %.1f", hlAtr1_1, InpEntryHLATR_Max);

      if(blockReason == "")
      {
         double slDist = sltp_atr1 * InpSL_ATR_Multi;
         double sl  = NormalizeDouble(bid + slDist, _Digits);
         double tp  = useFixedTP ? NormalizeDouble(bid - sltp_atr1 * InpTP_ATR_Multi, _Digits) : 0.0;
         if(!AdjustSellStops(bid, sl, tp))
         {
            if(InpPrintLog) Print("[Cond1 Sell Skip] Stops level invalid");
         }
         else if(AnyPositionLocked())
         {
            if(InpPrintLog) Print("[Cond1 Sell Skip] Existing position close to TP/SL");
         }
         else
         {
            slDist = sl - bid;
            double lot = CalcLot(slDist, bid, ORDER_TYPE_SELL);
            if(lot <= 0.0) Print("[Cond1 Sell Skip] Lot calc failed");
            else if(TrySellWithRetry(lot, bid, sl, tp, COMMENT_COND1_SELL))
            {
               if(InpPrintLog) PrintFormat("[Cond1 Sell] Bid=%.3f SL=%.3f TP=%s Lot=%.2f HL-ATR=%.3f D1=%s TF=%s Bars=%d",
                                            bid, sl, useFixedTP ? DoubleToString(tp,_Digits) : "HL-ATR",
                                            lot, hlAtr1_1,
                                            d1Dir<0?"SELL":"--", tfDir<0?"SELL":"--",
                                            g_barCount - g_sellSignalBar);
               g_sellSignal = false;
            }
         }
      }
      else if(InpPrintLog) PrintFormat("[Cond1 Sell Blocked] %s", blockReason);
   }

   //--- Cond.2 D1/TF exemption (Cond.2 may opt out of each filter) ---
   bool d1BuyOk_c2  = InpD1_Cond2Exempt || !InpD1FilterEnable || (d1Dir > 0);
   bool d1SellOk_c2 = InpD1_Cond2Exempt || !InpD1FilterEnable || (d1Dir < 0);
   bool tfBuyOk_c2  = InpTF_Cond2Exempt || !InpTFFilterEnable || (tfDir > 0);
   bool tfSellOk_c2 = InpTF_Cond2Exempt || !InpTFFilterEnable || (tfDir < 0);

   //==================================================================
   //  Cond.2: Camarilla zone reversal
   //  Near zone ceiling -> Sell / Near zone floor -> Buy
   //  + BB + HL-ATR + RSI confirmation
   //==================================================================
   if(InpEntry2Enable && time2Ok && InpCamarillaEnable && g_camS4 > 0.0)
   {
      if(!InpOnlyOnePos || !HasPosCond2())
      {
         double closeBar1 = cl[1];
         double nearBuf   = atr2[1] * InpCamNearATR;

         double zoneCeiling = 0.0, zoneFloor = 0.0;
         string zoneName = "";

         if     (closeBar1 >= g_camR3 && closeBar1 < g_camR4)
            { zoneCeiling = g_camR4; zoneFloor = g_camR3; zoneName = "R3-R4"; }
         else if(closeBar1 >= g_camR2 && closeBar1 < g_camR3)
            { zoneCeiling = g_camR3; zoneFloor = g_camR2; zoneName = "R2-R3"; }
         else if(closeBar1 >= g_camR1 && closeBar1 < g_camR2)
            { zoneCeiling = g_camR2; zoneFloor = g_camR1; zoneName = "R1-R2"; }
         else if(closeBar1 >= g_camS1 && closeBar1 < g_camR1)
            { zoneCeiling = g_camR1; zoneFloor = g_camS1; zoneName = "S1-R1"; }
         else if(closeBar1 >= g_camS2 && closeBar1 < g_camS1)
            { zoneCeiling = g_camS1; zoneFloor = g_camS2; zoneName = "S1-S2"; }
         else if(closeBar1 >= g_camS3 && closeBar1 < g_camS2)
            { zoneCeiling = g_camS2; zoneFloor = g_camS3; zoneName = "S2-S3"; }
         else if(closeBar1 >= g_camS4 && closeBar1 < g_camS3)
            { zoneCeiling = g_camS3; zoneFloor = g_camS4; zoneName = "S3-S4"; }

         if(zoneCeiling > 0.0 && zoneFloor > 0.0)
         {
            bool nearCeiling = (hi[1] >= zoneCeiling - nearBuf);
            bool nearFloor   = (lo[1] <= zoneFloor + nearBuf);

            //--- Buy: near floor + BB lower break + HL-ATR + RSI ---
            if(InpEntry2Buy && nearFloor
               && hlAtr1_2 >= InpHLATR_Reversal
               && lo[1] <= bb2Lower[1] && cl[1] <= bb2sLower[1]
               && rsi[1] <= InpC2_RSI_Buy
               && d1BuyOk_c2 && tfBuyOk_c2)
            {
               double slDist = sltp_atr2 * InpSL_ATR_Multi;
               double sl  = NormalizeDouble(ask - slDist, _Digits);

               double tp = 0.0;
               if(InpCamZoneTP && zoneCeiling > ask)
                  tp = NormalizeDouble(zoneCeiling, _Digits);
               else if(useFixedTP)
                  tp = NormalizeDouble(ask + sltp_atr2 * InpTP_ATR_Multi, _Digits);

               if(!AdjustBuyStops(ask, sl, tp))
               {
                  if(InpPrintLog) Print("[Cond2 Buy Skip] Stops level invalid");
               }
               else if(AnyPositionLocked())
               {
                  if(InpPrintLog) Print("[Cond2 Buy Skip] Existing position close to TP/SL");
               }
               else
               {
                  slDist = ask - sl;
                  double lot = CalcLot(slDist, ask, ORDER_TYPE_BUY);
                  if(lot <= 0.0) Print("[Cond2 Buy Skip] Lot calc failed");
                  else if(TryBuyWithRetry(lot, ask, sl, tp, COMMENT_COND2_BUY))
                  {
                     if(InpPrintLog) PrintFormat("[Cond2 Buy] Zone=%s Ask=%.2f SL=%.2f TP=%.2f Lot=%.2f | Floor=%.2f Lo=%.2f Ceiling=%.2f | HL-ATR=%.3f RSI=%.1f",
                                                  zoneName, ask, sl, tp, lot,
                                                  zoneFloor, lo[1], zoneCeiling, hlAtr1_2, rsi[1]);
                  }
               }
            }
            //--- Sell: near ceiling + BB upper break + HL-ATR + RSI ---
            else if(InpEntry2Sell && nearCeiling
               && hlAtr1_2 >= InpHLATR_Reversal
               && hi[1] >= bb2Upper[1] && cl[1] >= bb2sUpper[1]
               && rsi[1] >= InpC2_RSI_Sell
               && d1SellOk_c2 && tfSellOk_c2)
            {
               double slDist = sltp_atr2 * InpSL_ATR_Multi;
               double sl  = NormalizeDouble(bid + slDist, _Digits);

               double tp = 0.0;
               if(InpCamZoneTP && zoneFloor < bid)
                  tp = NormalizeDouble(zoneFloor, _Digits);
               else if(useFixedTP)
                  tp = NormalizeDouble(bid - sltp_atr2 * InpTP_ATR_Multi, _Digits);

               if(!AdjustSellStops(bid, sl, tp))
               {
                  if(InpPrintLog) Print("[Cond2 Sell Skip] Stops level invalid");
               }
               else if(AnyPositionLocked())
               {
                  if(InpPrintLog) Print("[Cond2 Sell Skip] Existing position close to TP/SL");
               }
               else
               {
                  slDist = sl - bid;
                  double lot = CalcLot(slDist, bid, ORDER_TYPE_SELL);
                  if(lot <= 0.0) Print("[Cond2 Sell Skip] Lot calc failed");
                  else if(TrySellWithRetry(lot, bid, sl, tp, COMMENT_COND2_SELL))
                  {
                     if(InpPrintLog) PrintFormat("[Cond2 Sell] Zone=%s Bid=%.2f SL=%.2f TP=%.2f Lot=%.2f | Floor=%.2f Hi=%.2f Ceiling=%.2f | HL-ATR=%.3f RSI=%.1f",
                                                  zoneName, bid, sl, tp, lot,
                                                  zoneFloor, hi[1], zoneCeiling, hlAtr1_2, rsi[1]);
                  }
               }
            }
            else if(InpDiagLog && (nearFloor || nearCeiling))
            {
               if(nearFloor)
               {
                  string reason = "";
                  if(!InpEntry2Buy)                reason = "Buy disabled";
                  else if(hlAtr1_2 < InpHLATR_Reversal) reason = StringFormat("HL-ATR=%.3f<%.1f", hlAtr1_2, InpHLATR_Reversal);
                  else if(lo[1] > bb2Lower[1])      reason = "BB lower not reached";
                  else if(rsi[1] > InpC2_RSI_Buy)   reason = StringFormat("RSI=%.1f>%.0f", rsi[1], InpC2_RSI_Buy);
                  else if(!d1BuyOk_c2)               reason = "D1 dir not BUY";
                  else if(!tfBuyOk_c2)               reason = "TF EMA not BUY";
                  PrintFormat("[Cond2 Buy Blocked] Zone=%s Floor=%.2f Lo=%.2f %s", zoneName, zoneFloor, lo[1], reason);
               }
               if(nearCeiling)
               {
                  string reason = "";
                  if(!InpEntry2Sell)               reason = "Sell disabled";
                  else if(hlAtr1_2 < InpHLATR_Reversal) reason = StringFormat("HL-ATR=%.3f<%.1f", hlAtr1_2, InpHLATR_Reversal);
                  else if(hi[1] < bb2Upper[1])      reason = "BB upper not reached";
                  else if(rsi[1] < InpC2_RSI_Sell)  reason = StringFormat("RSI=%.1f<%.0f", rsi[1], InpC2_RSI_Sell);
                  else if(!d1SellOk_c2)              reason = "D1 dir not SELL";
                  else if(!tfSellOk_c2)              reason = "TF EMA not SELL";
                  PrintFormat("[Cond2 Sell Blocked] Zone=%s Ceiling=%.2f Hi=%.2f %s", zoneName, zoneCeiling, hi[1], reason);
               }
            }
         }
      }
   }
}

//==================================================================
//  CalcLot
//==================================================================
double CalcLot(const double slPrice, const double entryPrice,
               const ENUM_ORDER_TYPE orderType)
{
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   if(!InpAutoLot)
   {
      double fixedLot = NormalizeLot(InpFixedLot);
      return ClampByMargin(fixedLot, entryPrice, orderType, freeMargin);
   }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) { Print("CalcLot: Cannot get balance"); return 0.0; }

   double baseAmount = balance   * (InpMarginPct / 100.0);
   double riskAmount = baseAmount * (InpRiskPct   / 100.0);

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0 || slPrice <= 0.0) { Print("CalcLot: Invalid TickSize/SLPrice"); return 0.0; }

   double tickValueProfit = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
   if(tickValueProfit <= 0.0) { Print("CalcLot: Invalid TICK_VALUE_PROFIT"); return 0.0; }

   string accountCcy = AccountInfoString(ACCOUNT_CURRENCY);
   string profitCcy  = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   double fxRate     = 1.0;

   if(accountCcy != profitCcy)
   {
      string pairDirect = profitCcy + accountCcy;
      fxRate = SymbolInfoDouble(pairDirect, SYMBOL_ASK);
      if(fxRate <= 0.0)
      {
         string pairInverse = accountCcy + profitCcy;
         double rateInverse = SymbolInfoDouble(pairInverse, SYMBOL_ASK);
         if(rateInverse > 0.0) fxRate = 1.0 / rateInverse;
         else
         {
            PrintFormat("[CalcLot] Warning: FX rate unavailable (%s/%s) using fallback", pairDirect, pairInverse);
            double tvFallback = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
            if(tvFallback > 0.0)
            {
               double lpFb = (slPrice / tickSize) * tvFallback;
               if(lpFb > 0.0) return ClampByMargin(NormalizeLot(riskAmount / lpFb), entryPrice, orderType, freeMargin);
            }
            return 0.0;
         }
      }
   }

   double lossPerLot = (slPrice / tickSize) * (tickValueProfit * fxRate);
   if(lossPerLot <= 0.0) { Print("CalcLot: lossPerLot<=0"); return 0.0; }

   double lot = NormalizeLot(riskAmount / lossPerLot);
   lot = ClampByMargin(lot, entryPrice, orderType, freeMargin);

   if(InpPrintLog)
      PrintFormat("[CalcLot] AccCcy=%s ProfitCcy=%s Rate=%.5f | Balance=%.2f Risk=%.2f SL=%.5f LossPerLot=%.2f -> Lot=%.2f",
                  accountCcy, profitCcy, fxRate, balance, riskAmount, slPrice, lossPerLot, lot);
   return lot;
}

//==================================================================
//  ClampByMargin
//  Reduces lot to fit within free margin. Returns 0 if not feasible.
//==================================================================
double ClampByMargin(double lot, const double entryPrice,
                     const ENUM_ORDER_TYPE orderType, const double freeMargin)
{
   const double SAFETY = 0.80;   // Use up to 80% of free margin

   if(lot <= 0.0 || freeMargin <= 0.0) return 0.0;

   double requiredMargin = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, lot, entryPrice, requiredMargin))
   {
      Print("[CalcLot] OrderCalcMargin failed - skipping trade");
      return 0.0;
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   // Lot fits within safety threshold
   if(requiredMargin <= freeMargin * SAFETY) return lot;

   // Need to reduce
   double marginPerLot = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, 1.0, entryPrice, marginPerLot))
   {
      Print("[CalcLot] marginPerLot calc failed - skipping trade");
      return 0.0;
   }
   if(marginPerLot <= 0.0) return 0.0;

   double safeLot = NormalizeLot((freeMargin * SAFETY) / marginPerLot);
   if(InpPrintLog)
      PrintFormat("[CalcLot] Margin reduced: %.2f->%.2f (required=%.2f free=%.2f)",
                  lot, safeLot, requiredMargin, freeMargin);

   if(safeLot < minLot)
   {
      if(InpPrintLog) PrintFormat("[CalcLot] Reduced lot %.2f < min lot %.2f - skip", safeLot, minLot);
      return 0.0;
   }

   // Final sanity check - ensure NormalizeLot rounding didn't push us back over the limit
   double finalRequired = 0.0;
   if(OrderCalcMargin(orderType, _Symbol, safeLot, entryPrice, finalRequired))
   {
      if(finalRequired > freeMargin * SAFETY)
      {
         if(InpPrintLog) PrintFormat("[CalcLot] Final check: %.2f > %.2f - skip", finalRequired, freeMargin * SAFETY);
         return 0.0;
      }
   }
   return safeLot;
}

//==================================================================
//  Sum of open positions and pending orders volume on _Symbol.
//  Includes ALL positions on the symbol (not only this EA's),
//  because SYMBOL_VOLUME_LIMIT is a per-symbol cap enforced by broker.
//==================================================================
double GetSymbolTotalVolume()
{
   double total = 0.0;

   // Open positions
   int posTotal = PositionsTotal();
   for(int i = 0; i < posTotal; i++)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      total += PositionGetDouble(POSITION_VOLUME);
   }

   // Pending orders
   int ordTotal = OrdersTotal();
   for(int i = 0; i < ordTotal; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      total += OrderGetDouble(ORDER_VOLUME_CURRENT);
   }
   return total;
}

//==================================================================
//  NormalizeLot
//==================================================================
double NormalizeLot(double lot)
{
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(InpMaxLot         > 0.0) maxLot = MathMin(maxLot, InpMaxLot);
   if(InpMinLotOverride > 0.0) minLot = MathMax(minLot, InpMinLotOverride);

   // SYMBOL_VOLUME_LIMIT: cumulative cap (open + pending). 0 = no limit.
   double volLimit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(volLimit > 0.0)
   {
      double currentVol = GetSymbolTotalVolume();
      double remaining  = volLimit - currentVol;
      if(remaining <= 0.0)
      {
         if(InpPrintLog) PrintFormat("[NormalizeLot] Volume limit reached: %.2f/%.2f", currentVol, volLimit);
         return 0.0;
      }
      maxLot = MathMin(maxLot, remaining);
   }

   if(lotStep > 0.0) lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMin(lot, maxLot);

   if(lot < minLot)
   {
      if(InpPrintLog) PrintFormat("[NormalizeLot] Lot %.4f below min %.2f - skip", lot, minLot);
      return 0.0;
   }

   int digits = (lotStep > 0.0) ? (int)MathRound(-MathLog10(lotStep)) : 2;
   return NormalizeDouble(lot, MathMax(digits, 0));
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
