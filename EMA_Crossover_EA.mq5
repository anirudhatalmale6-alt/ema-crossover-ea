//+------------------------------------------------------------------+
//|                                          EMA_Crossover_EA.mq5     |
//|                                          Copyright 2026            |
//|                  EMA 9/33 Crossover + Hammer/Shooting Star + RSI   |
//+------------------------------------------------------------------+
#property copyright "EMA Crossover EA v1.4"
#property version   "1.40"
#property description "EMA 9/33 Crossover + Hammer Pattern + RSI(2) Filter"
#property description "Designed for Gold (XAUUSD) on M1 timeframe"
#property description "Hidden SL (manual close) + up to 40 lot tiers"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                   |
//+------------------------------------------------------------------+

input group "══════ EMA Settings ══════"
input int      EMA_Fast_Period   = 9;          // Fast EMA Period
input int      EMA_Slow_Period   = 33;         // Slow EMA Period
input int      Max_Candles       = 15;         // Max candles after cross for entry
input int      HighLow_Lookback  = 7;          // Lookback bars for highest/lowest check
input double   TP_Multiplier     = 5.0;        // Take Profit multiplier (x wick distance)

input group "══════ RSI Filter ══════"
input int      RSI_Period        = 2;          // RSI Period
input double   RSI_Oversold      = 5.0;        // RSI Oversold level (Buy when RSI below this)
input double   RSI_Overbought    = 95.0;       // RSI Overbought level (Sell when RSI above this)

input group "══════ Hammer Pattern Settings ══════"
input double   Hammer_WickRatio  = 2.0;        // Min wick-to-body ratio (2.0 = wick must be 2x body)
input double   Hammer_MaxShort   = 0.3;        // Max short wick as fraction of total range (0.3 = 30%)

input group "══════ Time Filter (Server Time) ══════"
input int      Market_Open_Hour  = 1;          // Daily Market Open Hour
input int      Market_Open_Min   = 0;          // Daily Market Open Minute
input int      Market_Close_Hour = 23;         // Daily Market Close Hour
input int      Market_Close_Min  = 59;         // Daily Market Close Minute
input int      Open_Delay_Min    = 60;         // Minutes after open to start trading
input int      Close_Before_Min  = 10;         // Minutes before close to exit all trades

input group "══════ Trade Settings ══════"
input double   Default_Lot       = 0.01;       // Default Lot Size (if no tier matches)
input int      Magic_Number      = 202601;     // Magic Number
input int      Max_Slippage      = 30;         // Maximum Slippage (points)

//--- Sell Lot Tiers: Format per entry is  minPts-maxPts:lotSize
//--- Example: 0-100:0.01, 100-200:0.02, 200-300:0.05
//--- Split across 4 boxes (up to 10 tiers each = 40 total)

input group "══════ Sell Lot Tiers (High-to-Close pts) ══════"
input string   Sell_Tiers_1  = "0-50:0.01, 50-100:0.02, 100-150:0.03, 150-200:0.04, 200-250:0.05, 250-300:0.06, 300-350:0.07, 350-400:0.08, 400-450:0.09, 450-500:0.10";  // Sell Tiers 1-10
input string   Sell_Tiers_2  = "";  // Sell Tiers 11-20
input string   Sell_Tiers_3  = "";  // Sell Tiers 21-30
input string   Sell_Tiers_4  = "";  // Sell Tiers 31-40

input group "══════ Buy Lot Tiers (Low-to-Close pts) ══════"
input string   Buy_Tiers_1   = "0-50:0.01, 50-100:0.02, 100-150:0.03, 150-200:0.04, 200-250:0.05, 250-300:0.06, 300-350:0.07, 350-400:0.08, 400-450:0.09, 450-500:0.10";  // Buy Tiers 1-10
input string   Buy_Tiers_2   = "";  // Buy Tiers 11-20
input string   Buy_Tiers_3   = "";  // Buy Tiers 21-30
input string   Buy_Tiers_4   = "";  // Buy Tiers 31-40

//+------------------------------------------------------------------+
//| Lot Tier Structure                                                 |
//+------------------------------------------------------------------+

struct LotTier
{
   double minPts;
   double maxPts;
   double lotSize;
};

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+

int    g_handleEMAFast;
int    g_handleEMASlow;
int    g_handleRSI;
CTrade g_trade;

datetime g_lastBarTime    = 0;
int      g_crossDir       = 0;     // 1 = sell signal, -1 = buy signal, 0 = none
int      g_barsSinceCross = 0;
bool     g_tradeTaken     = false;
int      g_prevEMARelation= 0;     // 1 = slow > fast, -1 = slow < fast

LotTier  g_sellTiers[];
LotTier  g_buyTiers[];
int      g_sellTierCount  = 0;
int      g_buyTierCount   = 0;

//--- Manual SL tracking (hidden stop loss)
double   g_manualSL       = 0;     // Price level to close trade at
int      g_tradeDir       = 0;     // 1 = sell position, -1 = buy position

//+------------------------------------------------------------------+
//| Parse a single tier string into the tier array                     |
//+------------------------------------------------------------------+
bool ParseTierString(string tierStr, LotTier &tiers[], int &count)
{
   StringTrimLeft(tierStr);
   StringTrimRight(tierStr);

   if(StringLen(tierStr) == 0)
      return true;

   string entries[];
   int numEntries = StringSplit(tierStr, ',', entries);

   for(int i = 0; i < numEntries; i++)
   {
      string entry = entries[i];
      StringTrimLeft(entry);
      StringTrimRight(entry);

      if(StringLen(entry) == 0) continue;

      int dashPos = StringFind(entry, "-");
      if(dashPos <= 0)
      {
         Print("WARNING: Invalid tier format (no dash): ", entry);
         continue;
      }

      int colonPos = StringFind(entry, ":");
      if(colonPos <= 0 || colonPos <= dashPos)
      {
         Print("WARNING: Invalid tier format (no colon): ", entry);
         continue;
      }

      string minStr = StringSubstr(entry, 0, dashPos);
      string maxStr = StringSubstr(entry, dashPos + 1, colonPos - dashPos - 1);
      string lotStr = StringSubstr(entry, colonPos + 1);

      StringTrimLeft(minStr);  StringTrimRight(minStr);
      StringTrimLeft(maxStr);  StringTrimRight(maxStr);
      StringTrimLeft(lotStr);  StringTrimRight(lotStr);

      double minVal = StringToDouble(minStr);
      double maxVal = StringToDouble(maxStr);
      double lotVal = StringToDouble(lotStr);

      if(maxVal <= minVal || lotVal <= 0)
      {
         Print("WARNING: Invalid tier values: min=", minVal, " max=", maxVal, " lot=", lotVal);
         continue;
      }

      int idx = count;
      count++;
      ArrayResize(tiers, count);

      tiers[idx].minPts  = minVal;
      tiers[idx].maxPts  = maxVal;
      tiers[idx].lotSize = lotVal;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Parse all 4 tier input strings for a direction                     |
//+------------------------------------------------------------------+
void ParseAllTiers(string s1, string s2, string s3, string s4,
                   LotTier &tiers[], int &count)
{
   count = 0;
   ArrayResize(tiers, 0);

   ParseTierString(s1, tiers, count);
   ParseTierString(s2, tiers, count);
   ParseTierString(s3, tiers, count);
   ParseTierString(s4, tiers, count);
}

//+------------------------------------------------------------------+
//| Look up lot size from tier array based on point distance           |
//+------------------------------------------------------------------+
double LookupLot(double points, const LotTier &tiers[], int count)
{
   for(int i = 0; i < count; i++)
   {
      if(points >= tiers[i].minPts && points < tiers[i].maxPts)
         return tiers[i].lotSize;
   }
   return Default_Lot;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_handleEMAFast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_handleRSI     = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);

   if(g_handleEMAFast == INVALID_HANDLE || g_handleEMASlow == INVALID_HANDLE || g_handleRSI == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA/RSI indicators");
      return INIT_FAILED;
   }

   //--- Parse lot size tiers
   ParseAllTiers(Sell_Tiers_1, Sell_Tiers_2, Sell_Tiers_3, Sell_Tiers_4,
                 g_sellTiers, g_sellTierCount);
   ParseAllTiers(Buy_Tiers_1, Buy_Tiers_2, Buy_Tiers_3, Buy_Tiers_4,
                 g_buyTiers, g_buyTierCount);

   Print("Sell lot tiers loaded: ", g_sellTierCount);
   for(int i = 0; i < g_sellTierCount; i++)
      Print("  Sell Tier ", i+1, ": ", g_sellTiers[i].minPts, "-",
            g_sellTiers[i].maxPts, " pts = ", g_sellTiers[i].lotSize, " lots");

   Print("Buy lot tiers loaded: ", g_buyTierCount);
   for(int i = 0; i < g_buyTierCount; i++)
      Print("  Buy Tier ", i+1, ": ", g_buyTiers[i].minPts, "-",
            g_buyTiers[i].maxPts, " pts = ", g_buyTiers[i].lotSize, " lots");

   //--- Configure trade object
   g_trade.SetExpertMagicNumber(Magic_Number);
   g_trade.SetDeviationInPoints(Max_Slippage);

   //--- Initialize EMA relationship from history
   double emaFast[2], emaSlow[2];
   if(CopyBuffer(g_handleEMAFast, 0, 1, 2, emaFast) >= 2 &&
      CopyBuffer(g_handleEMASlow, 0, 1, 2, emaSlow) >= 2)
   {
      ArraySetAsSeries(emaFast, true);
      ArraySetAsSeries(emaSlow, true);
      if(emaSlow[0] > emaFast[0])      g_prevEMARelation = 1;
      else if(emaSlow[0] < emaFast[0]) g_prevEMARelation = -1;
   }

   //--- Reset manual SL tracking
   g_manualSL  = 0;
   g_tradeDir  = 0;

   Print("EMA Crossover EA v1.4 initialized | EMA ", EMA_Fast_Period, "/", EMA_Slow_Period,
         " | RSI(", RSI_Period, ") OB:", DoubleToString(RSI_Overbought, 1), " OS:", DoubleToString(RSI_Oversold, 1),
         " | Hammer Wick Ratio: ", DoubleToString(Hammer_WickRatio, 1),
         " | TP x", DoubleToString(TP_Multiplier, 1), " | Magic: ", Magic_Number,
         " | Hidden SL | Sell Tiers: ", g_sellTierCount, " | Buy Tiers: ", g_buyTierCount);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_handleEMAFast != INVALID_HANDLE) IndicatorRelease(g_handleEMAFast);
   if(g_handleEMASlow != INVALID_HANDLE) IndicatorRelease(g_handleEMASlow);
   if(g_handleRSI     != INVALID_HANDLE) IndicatorRelease(g_handleRSI);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Always check close time (runs every tick)
   if(IsCloseTime())
   {
      CloseAllTrades();
      g_manualSL = 0;
      g_tradeDir = 0;
      return;
   }

   //--- MANUAL SL CHECK (every tick, hidden from broker)
   CheckManualSL();

   //--- If position was closed (by TP or manual SL), reset tracking
   if(g_manualSL != 0 && !HasOpenPosition())
   {
      g_manualSL = 0;
      g_tradeDir = 0;
   }

   //--- Only process entry logic on new bar
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   //--- Get EMA values for bars 0, 1, 2
   double emaFast[3], emaSlow[3];
   if(CopyBuffer(g_handleEMAFast, 0, 0, 3, emaFast) < 3) return;
   if(CopyBuffer(g_handleEMASlow, 0, 0, 3, emaSlow) < 3) return;
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   //--- Detect EMA crossover on completed bar (bar 1 vs bar 2)
   int currRelation = 0;
   if(emaSlow[1] > emaFast[1])      currRelation = 1;
   else if(emaSlow[1] < emaFast[1]) currRelation = -1;

   //--- Cross detected when relationship changes
   if(g_prevEMARelation != 0 && currRelation != 0 && g_prevEMARelation != currRelation)
   {
      if(currRelation == 1)
      {
         g_crossDir       = 1;
         g_barsSinceCross = 0;
         g_tradeTaken     = false;
         Print(">>> SIGNAL: EMA", EMA_Slow_Period, " crossed ABOVE EMA", EMA_Fast_Period, " -> SELL");
      }
      else if(currRelation == -1)
      {
         g_crossDir       = -1;
         g_barsSinceCross = 0;
         g_tradeTaken     = false;
         Print(">>> SIGNAL: EMA", EMA_Slow_Period, " crossed BELOW EMA", EMA_Fast_Period, " -> BUY");
      }
   }

   if(currRelation != 0)
      g_prevEMARelation = currRelation;

   //--- Update chart comment
   UpdateChartComment(emaFast[0], emaSlow[0]);

   //--- Increment bar counter for active signal
   if(g_crossDir != 0)
      g_barsSinceCross++;

   //--- Check if we should look for entry
   if(g_crossDir == 0)                         return;
   if(g_barsSinceCross > Max_Candles)           return;
   if(g_tradeTaken)                             return;
   if(!IsTradingTime())                         return;
   if(HasOpenPosition())                        return;

   //--- RSI(2) filter: check entry candle (bar 1) or 1 candle before (bar 2)
   double rsiVals[3];
   if(CopyBuffer(g_handleRSI, 0, 0, 3, rsiVals) < 3) return;
   ArraySetAsSeries(rsiVals, true);

   //--- For SELL: RSI(2) must be > RSI_Overbought on bar 1 or bar 2
   //--- For BUY:  RSI(2) must be < RSI_Oversold on bar 1 or bar 2
   if(g_crossDir == 1)
   {
      if(rsiVals[1] <= RSI_Overbought && rsiVals[2] <= RSI_Overbought)
         return;
   }
   else if(g_crossDir == -1)
   {
      if(rsiVals[1] >= RSI_Oversold && rsiVals[2] >= RSI_Oversold)
         return;
   }

   //--- Analyze the completed candle (bar 1)
   double op  = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double hi  = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double lo  = iLow(_Symbol, PERIOD_CURRENT, 1);
   double cl  = iClose(_Symbol, PERIOD_CURRENT, 1);
   double ema33 = emaSlow[1];

   if(g_crossDir == 1)
      CheckSellEntry(op, hi, lo, cl, ema33);
   else if(g_crossDir == -1)
      CheckBuyEntry(op, hi, lo, cl, ema33);
}

//+------------------------------------------------------------------+
//| MANUAL SL: Check price on every tick and close if crossed          |
//+------------------------------------------------------------------+
void CheckManualSL()
{
   if(g_manualSL == 0 || g_tradeDir == 0) return;
   if(!HasOpenPosition()) return;

   if(g_tradeDir == 1)  // SELL position: close if Ask crosses above candle high
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask >= g_manualSL)
      {
         Print(StringFormat("MANUAL SL HIT (Sell): Ask=%.2f >= SL=%.2f -> Closing", ask, g_manualSL));
         CloseAllTrades();
         g_manualSL = 0;
         g_tradeDir = 0;
      }
   }
   else if(g_tradeDir == -1)  // BUY position: close if Bid crosses below candle low
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid <= g_manualSL)
      {
         Print(StringFormat("MANUAL SL HIT (Buy): Bid=%.2f <= SL=%.2f -> Closing", bid, g_manualSL));
         CloseAllTrades();
         g_manualSL = 0;
         g_tradeDir = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| Detect SHOOTING STAR pattern (for sell trades)                     |
//| Long upper wick, small body, small lower wick                      |
//+------------------------------------------------------------------+
bool IsShootingStar(double op, double hi, double lo, double cl)
{
   double range = hi - lo;
   if(range <= 0) return false;

   double body       = MathAbs(cl - op);
   double upperWick  = hi - MathMax(op, cl);   // from body top to high
   double lowerWick  = MathMin(op, cl) - lo;   // from body bottom to low

   //--- Upper wick must be >= Hammer_WickRatio * body
   if(body > 0 && upperWick < Hammer_WickRatio * body)
      return false;

   //--- If body is zero (doji), upper wick must be > 50% of range
   if(body == 0 && upperWick < range * 0.5)
      return false;

   //--- Lower wick must be small (< Hammer_MaxShort of total range)
   if(lowerWick > Hammer_MaxShort * range)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Detect HAMMER pattern (for buy trades)                             |
//| Long lower wick, small body, small upper wick                      |
//+------------------------------------------------------------------+
bool IsHammer(double op, double hi, double lo, double cl)
{
   double range = hi - lo;
   if(range <= 0) return false;

   double body       = MathAbs(cl - op);
   double upperWick  = hi - MathMax(op, cl);
   double lowerWick  = MathMin(op, cl) - lo;

   //--- Lower wick must be >= Hammer_WickRatio * body
   if(body > 0 && lowerWick < Hammer_WickRatio * body)
      return false;

   //--- If body is zero (doji), lower wick must be > 50% of range
   if(body == 0 && lowerWick < range * 0.5)
      return false;

   //--- Upper wick must be small (< Hammer_MaxShort of total range)
   if(upperWick > Hammer_MaxShort * range)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| SELL ENTRY: Shooting Star + RSI > 95 + EMA cross                  |
//+------------------------------------------------------------------+
void CheckSellEntry(double op, double hi, double lo, double cl, double ema33)
{
   //--- Candle High must be the highest of previous N candles
   if(!IsHighestHigh(hi, 1))
      return;

   //--- Candle must be above the 33 EMA (check both open and close)
   if(MathMin(op, cl) < ema33)
      return;

   //--- Must be a Shooting Star pattern
   if(!IsShootingStar(op, hi, lo, cl))
      return;

   //--- Calculate wick distance and TP
   double highToClose = hi - cl;
   if(highToClose <= 0) highToClose = hi - op;  // if bull candle, use hi - max(op,cl)
   highToClose = hi - MathMax(op, cl);           // upper wick = distance from top of body to high
   if(highToClose <= 0) return;

   double tp = NormalizeDouble(MathMax(op, cl) - (TP_Multiplier * highToClose), _Digits);

   //--- Get lot size from tiers (based on upper wick in points)
   double pointDist = highToClose / _Point;
   double lot = LookupLot(pointDist, g_sellTiers, g_sellTierCount);
   lot = NormalizeLot(lot);

   //--- Place sell order (NO SL on order, TP only)
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(g_trade.Sell(lot, _Symbol, price, 0, tp,
      StringFormat("EMA%d/%d ShootStar | Wick:%.0fpts", EMA_Fast_Period, EMA_Slow_Period, pointDist)))
   {
      g_tradeTaken = true;
      g_manualSL   = NormalizeDouble(hi, _Digits);  // Hidden SL at candle High
      g_tradeDir   = 1;
      Print(StringFormat("SELL OPENED: Price=%.2f Lot=%.2f HiddenSL=%.2f TP=%.2f Wick=%.0fpts",
            price, lot, g_manualSL, tp, pointDist));
   }
   else
   {
      Print("SELL FAILED: Error ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| BUY ENTRY: Hammer + RSI < 5 + EMA cross                          |
//+------------------------------------------------------------------+
void CheckBuyEntry(double op, double hi, double lo, double cl, double ema33)
{
   //--- Candle Low must be the lowest of previous N candles
   if(!IsLowestLow(lo, 1))
      return;

   //--- Candle must be below the 33 EMA (check both open and close)
   if(MathMax(op, cl) > ema33)
      return;

   //--- Must be a Hammer pattern
   if(!IsHammer(op, hi, lo, cl))
      return;

   //--- Calculate wick distance and TP
   double lowToClose = MathMin(op, cl) - lo;  // lower wick = distance from body bottom to low
   if(lowToClose <= 0) return;

   double tp = NormalizeDouble(MathMin(op, cl) + (TP_Multiplier * lowToClose), _Digits);

   //--- Get lot size from tiers (based on lower wick in points)
   double pointDist = lowToClose / _Point;
   double lot = LookupLot(pointDist, g_buyTiers, g_buyTierCount);
   lot = NormalizeLot(lot);

   //--- Place buy order (NO SL on order, TP only)
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(g_trade.Buy(lot, _Symbol, price, 0, tp,
      StringFormat("EMA%d/%d Hammer | Wick:%.0fpts", EMA_Fast_Period, EMA_Slow_Period, pointDist)))
   {
      g_tradeTaken = true;
      g_manualSL   = NormalizeDouble(lo, _Digits);  // Hidden SL at candle Low
      g_tradeDir   = -1;
      Print(StringFormat("BUY OPENED: Price=%.2f Lot=%.2f HiddenSL=%.2f TP=%.2f Wick=%.0fpts",
            price, lot, g_manualSL, tp, pointDist));
   }
   else
   {
      Print("BUY FAILED: Error ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Check if candle high is the highest among previous N candles       |
//+------------------------------------------------------------------+
bool IsHighestHigh(double high, int barIndex)
{
   for(int i = barIndex + 1; i <= barIndex + HighLow_Lookback; i++)
   {
      if(iHigh(_Symbol, PERIOD_CURRENT, i) >= high)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Check if candle low is the lowest among previous N candles         |
//+------------------------------------------------------------------+
bool IsLowestLow(double low, int barIndex)
{
   for(int i = barIndex + 1; i <= barIndex + HighLow_Lookback; i++)
   {
      if(iLow(_Symbol, PERIOD_CURRENT, i) <= low)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Normalize lot size to broker requirements                          |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, lot);
   lot = MathMin(maxLot, lot);

   if(lotStep > 0)
      lot = MathFloor(lot / lotStep) * lotStep;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Check if current time is within trading hours                      |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);

   int nowMin   = dt.hour * 60 + dt.min;
   int openMin  = Market_Open_Hour * 60 + Market_Open_Min;
   int closeMin = Market_Close_Hour * 60 + Market_Close_Min;
   int startMin = openMin + Open_Delay_Min;
   int endMin   = closeMin - Close_Before_Min;

   return (nowMin >= startMin && nowMin < endMin);
}

//+------------------------------------------------------------------+
//| Check if it's time to close all trades                             |
//+------------------------------------------------------------------+
bool IsCloseTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);

   int nowMin   = dt.hour * 60 + dt.min;
   int closeMin = Market_Close_Hour * 60 + Market_Close_Min;
   int exitMin  = closeMin - Close_Before_Min;

   return (nowMin >= exitMin);
}

//+------------------------------------------------------------------+
//| Check for open positions with this magic number                    |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == Magic_Number)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close all positions with this magic number                         |
//+------------------------------------------------------------------+
void CloseAllTrades()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == Magic_Number)
         {
            if(g_trade.PositionClose(ticket))
               Print("Position ", ticket, " closed");
            else
               Print("Failed to close position ", ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Update chart comment with EA status                                |
//+------------------------------------------------------------------+
void UpdateChartComment(double emaFastVal, double emaSlowVal)
{
   string signal = "None";
   if(g_crossDir == 1)  signal = "SELL";
   if(g_crossDir == -1) signal = "BUY";

   string status = "";
   if(g_tradeTaken)
      status = " [Trade Taken]";
   else if(g_crossDir != 0 && g_barsSinceCross <= Max_Candles)
      status = StringFormat(" [Scanning %d/%d]", g_barsSinceCross, Max_Candles);
   else if(g_crossDir != 0 && g_barsSinceCross > Max_Candles)
      status = " [Window Expired]";

   string tradingStatus = IsTradingTime() ? "ACTIVE" : "PAUSED";
   if(IsCloseTime()) tradingStatus = "CLOSING";

   string slInfo = "";
   if(g_manualSL != 0)
      slInfo = StringFormat("\nHidden SL: %.2f (%s)", g_manualSL, g_tradeDir == 1 ? "Sell" : "Buy");

   //--- Get current RSI value for display
   double rsiCurr[1];
   double rsiDisplay = 0;
   if(CopyBuffer(g_handleRSI, 0, 1, 1, rsiCurr) >= 1)
      rsiDisplay = rsiCurr[0];

   Comment(StringFormat(
      "====== EMA Crossover EA v1.4 ======\n"
      "EMA %d: %.2f  |  EMA %d: %.2f\n"
      "RSI(%d): %.1f  |  OB: %.0f  OS: %.0f\n"
      "Hammer Wick Ratio: %.1f  |  Max Short: %.0f%%\n"
      "Signal: %s%s\n"
      "Trading: %s\n"
      "Sell Tiers: %d  |  Buy Tiers: %d\n"
      "Open Positions: %s%s\n"
      "===================================",
      EMA_Fast_Period, emaFastVal, EMA_Slow_Period, emaSlowVal,
      RSI_Period, rsiDisplay, RSI_Overbought, RSI_Oversold,
      Hammer_WickRatio, Hammer_MaxShort * 100,
      signal, status,
      tradingStatus,
      g_sellTierCount, g_buyTierCount,
      HasOpenPosition() ? "Yes" : "No",
      slInfo
   ));
}
//+------------------------------------------------------------------+
