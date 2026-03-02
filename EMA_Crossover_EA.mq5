//+------------------------------------------------------------------+
//|                                          EMA_Crossover_EA.mq5     |
//|                                          Copyright 2026            |
//|                  EMA 9/33 Crossover with Candle Structure Filter   |
//+------------------------------------------------------------------+
#property copyright "EMA Crossover EA v1.1"
#property version   "1.10"
#property description "EMA 9/33 Crossover Strategy with Candle Structure Filter"
#property description "Designed for Gold (XAUUSD) on M1 timeframe"
#property description "Supports up to 40 lot size tiers for Buy and Sell"

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

//+------------------------------------------------------------------+
//| Parse a single tier string into the tier array                     |
//| Format: "minPts-maxPts:lotSize, minPts-maxPts:lotSize, ..."       |
//+------------------------------------------------------------------+
bool ParseTierString(string tierStr, LotTier &tiers[], int &count)
{
   StringTrimLeft(tierStr);
   StringTrimRight(tierStr);

   if(StringLen(tierStr) == 0)
      return true;  // Empty string is OK, skip

   string entries[];
   int numEntries = StringSplit(tierStr, ',', entries);

   for(int i = 0; i < numEntries; i++)
   {
      string entry = entries[i];
      StringTrimLeft(entry);
      StringTrimRight(entry);

      if(StringLen(entry) == 0) continue;

      //--- Find the '-' between min and max
      int dashPos = StringFind(entry, "-");
      if(dashPos <= 0)
      {
         Print("WARNING: Invalid tier format (no dash): ", entry);
         continue;
      }

      //--- Find the ':' between max and lot size
      int colonPos = StringFind(entry, ":");
      if(colonPos <= 0 || colonPos <= dashPos)
      {
         Print("WARNING: Invalid tier format (no colon): ", entry);
         continue;
      }

      //--- Extract the three values
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

      //--- Add to array
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
   //--- Create EMA indicators
   g_handleEMAFast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(g_handleEMAFast == INVALID_HANDLE || g_handleEMASlow == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA indicators");
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

   Print("EMA Crossover EA v1.1 initialized | EMA ", EMA_Fast_Period, "/", EMA_Slow_Period,
         " | TP x", DoubleToString(TP_Multiplier, 1), " | Magic: ", Magic_Number,
         " | Sell Tiers: ", g_sellTierCount, " | Buy Tiers: ", g_buyTierCount);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_handleEMAFast != INVALID_HANDLE) IndicatorRelease(g_handleEMAFast);
   if(g_handleEMASlow != INVALID_HANDLE) IndicatorRelease(g_handleEMASlow);
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
      return;
   }

   //--- Only process logic on new bar
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
      if(currRelation == 1)  // 33 EMA crossed ABOVE 9 EMA -> Sell signal
      {
         g_crossDir       = 1;
         g_barsSinceCross = 0;
         g_tradeTaken     = false;
         Print(">>> SIGNAL: EMA", EMA_Slow_Period, " crossed ABOVE EMA", EMA_Fast_Period, " -> SELL");
      }
      else if(currRelation == -1)  // 33 EMA crossed BELOW 9 EMA -> Buy signal
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
   if(g_crossDir == 0)                         return;  // No signal
   if(g_barsSinceCross > Max_Candles)           return;  // Window expired
   if(g_tradeTaken)                             return;  // Already traded this signal
   if(!IsTradingTime())                         return;  // Outside trading hours
   if(HasOpenPosition())                        return;  // Already have a position

   //--- Analyze the completed candle (bar 1)
   double op  = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double hi  = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double lo  = iLow(_Symbol, PERIOD_CURRENT, 1);
   double cl  = iClose(_Symbol, PERIOD_CURRENT, 1);
   double ema33 = emaSlow[1];

   bool isBear = (cl < op);

   //--- Check entry conditions
   if(g_crossDir == 1)
      CheckSellEntry(op, hi, lo, cl, ema33, isBear);
   else if(g_crossDir == -1)
      CheckBuyEntry(op, hi, lo, cl, ema33, isBear);
}

//+------------------------------------------------------------------+
//| SELL ENTRY: Check candle conditions and place sell trade           |
//+------------------------------------------------------------------+
void CheckSellEntry(double op, double hi, double lo, double cl, double ema33, bool isBear)
{
   //--- Candle High must be the highest of previous 7 candles
   if(!IsHighestHigh(hi, 1))
      return;

   double wickUpper, wickLower, body;

   if(isBear)
   {
      //--- Bear candle: must NOT close below 33 EMA
      if(cl < ema33) return;

      wickUpper = hi - op;     // High to Open (upper wick)
      wickLower = cl - lo;     // Close to Low (lower wick)
      body      = op - cl;     // Open to Close (body)

      //--- Upper wick must be > lower wick AND > body
      if(wickUpper <= wickLower || wickUpper <= body) return;
   }
   else
   {
      //--- Bull candle: must NOT open below 33 EMA
      if(op < ema33) return;

      wickUpper = hi - cl;     // High to Close (upper wick)
      body      = cl - op;     // Close to Open (body)
      wickLower = op - lo;     // Open to Low (lower wick)

      //--- Upper wick must be > body AND > lower wick
      if(wickUpper <= body || wickUpper <= wickLower) return;
   }

   //--- Calculate SL and TP
   double highToClose = hi - cl;

   if(highToClose <= 0) return;  // Safety check

   double sl = NormalizeDouble(hi, _Digits);
   double tp = NormalizeDouble(cl - (TP_Multiplier * highToClose), _Digits);

   //--- Get lot size from tiers (based on High-to-Close distance in points)
   double pointDist = highToClose / _Point;
   double lot = LookupLot(pointDist, g_sellTiers, g_sellTierCount);
   lot = NormalizeLot(lot);

   //--- Place sell order at market
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(g_trade.Sell(lot, _Symbol, price, sl, tp,
      StringFormat("EMA%d/%d Sell | Wick:%.0fpts", EMA_Fast_Period, EMA_Slow_Period, pointDist)))
   {
      g_tradeTaken = true;
      Print(StringFormat("SELL OPENED: Price=%.2f Lot=%.2f SL=%.2f TP=%.2f H2C=%.0fpts",
            price, lot, sl, tp, pointDist));
   }
   else
   {
      Print("SELL FAILED: Error ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| BUY ENTRY: Check candle conditions and place buy trade            |
//+------------------------------------------------------------------+
void CheckBuyEntry(double op, double hi, double lo, double cl, double ema33, bool isBear)
{
   //--- Candle Low must be the lowest of previous 7 candles
   if(!IsLowestLow(lo, 1))
      return;

   double wickUpper, wickLower, body;

   if(isBear)
   {
      //--- Bear candle: must NOT open above 33 EMA
      if(op > ema33) return;

      wickLower = cl - lo;     // Close to Low (lower wick for bear)
      body      = op - cl;     // Open to Close (body)
      wickUpper = hi - op;     // High to Open (upper wick for bear)

      //--- Lower wick must be > body AND > upper wick
      if(wickLower <= body || wickLower <= wickUpper) return;
   }
   else
   {
      //--- Bull candle: must NOT close above 33 EMA
      if(cl > ema33) return;

      wickLower = op - lo;     // Open to Low (lower wick for bull)
      body      = cl - op;     // Close to Open (body)
      wickUpper = hi - cl;     // High to Close (upper wick for bull)

      //--- Lower wick must be > body AND > upper wick
      if(wickLower <= body || wickLower <= wickUpper) return;
   }

   //--- Calculate SL and TP
   double closeToLow = cl - lo;

   if(closeToLow <= 0) return;  // Safety check

   double sl = NormalizeDouble(lo, _Digits);
   double tp = NormalizeDouble(cl + (TP_Multiplier * closeToLow), _Digits);

   //--- Get lot size from tiers (based on Low-to-Close distance in points)
   double pointDist = closeToLow / _Point;
   double lot = LookupLot(pointDist, g_buyTiers, g_buyTierCount);
   lot = NormalizeLot(lot);

   //--- Place buy order at market
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(g_trade.Buy(lot, _Symbol, price, sl, tp,
      StringFormat("EMA%d/%d Buy | Wick:%.0fpts", EMA_Fast_Period, EMA_Slow_Period, pointDist)))
   {
      g_tradeTaken = true;
      Print(StringFormat("BUY OPENED: Price=%.2f Lot=%.2f SL=%.2f TP=%.2f L2C=%.0fpts",
            price, lot, sl, tp, pointDist));
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
               Print("Position ", ticket, " closed (market close time)");
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

   Comment(StringFormat(
      "====== EMA Crossover EA v1.1 ======\n"
      "EMA %d: %.2f  |  EMA %d: %.2f\n"
      "Signal: %s%s\n"
      "Trading: %s\n"
      "Sell Tiers: %d  |  Buy Tiers: %d\n"
      "Open Positions: %s\n"
      "===================================",
      EMA_Fast_Period, emaFastVal, EMA_Slow_Period, emaSlowVal,
      signal, status,
      tradingStatus,
      g_sellTierCount, g_buyTierCount,
      HasOpenPosition() ? "Yes" : "No"
   ));
}
//+------------------------------------------------------------------+
