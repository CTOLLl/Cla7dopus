//+------------------------------------------------------------------+
//|                                                   GridProEA.mq5  |
//|                          Professional Grid Expert Advisor (MQL5) |
//|                                                                  |
//|  Concept:                                                        |
//|    Mean-reversion grid trading with strict risk management.      |
//|    Entries based on RSI or Break of Structure (BoS).             |
//|    Strict equity protection, basket SL/TP, spread filter,        |
//|    dashboard, OOP design using CTrade.                           |
//|                                                                  |
//|  WARNING:                                                        |
//|    Grid / Martingale strategies carry significant risk.          |
//|    Always test thoroughly on demo before live deployment.        |
//+------------------------------------------------------------------+
#property copyright "GridProEA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_TRADE_DIRECTION
{
   DIR_BUY_ONLY  = 0,   // Buy only
   DIR_SELL_ONLY = 1,   // Sell only
   DIR_BOTH      = 2    // Bi-directional
};

enum ENUM_ENTRY_MODE
{
   ENTRY_RSI = 0,       // RSI oversold/overbought
   ENTRY_BOS = 1        // Break of Structure (recent high/low)
};

enum ENUM_LOT_MODE
{
   LOT_FIXED   = 0,     // Fixed lot size
   LOT_DYNAMIC = 1      // Dynamic (percent of equity / risk based)
};

enum ENUM_BASKET_TP_MODE
{
   BASKET_TP_OFF      = 0, // Basket TP disabled
   BASKET_TP_POINTS   = 1, // TP in average-price points
   BASKET_TP_MONEY    = 2  // TP in account currency
};

//+------------------------------------------------------------------+
//| Input parameters                                                 |
//+------------------------------------------------------------------+
input group "=== General ==="
input long                  InpMagic            = 20260525;     // Magic number
input string                InpComment          = "GridProEA";  // Order comment
input ENUM_TRADE_DIRECTION  InpDirection        = DIR_BOTH;     // Trading direction
input ENUM_ENTRY_MODE       InpEntryMode        = ENTRY_RSI;    // Entry signal source

input group "=== RSI Entry ==="
input int                   InpRSIPeriod        = 14;           // RSI period
input ENUM_TIMEFRAMES       InpRSITimeframe     = PERIOD_M15;   // RSI timeframe
input double                InpRSIOversold      = 30.0;         // RSI oversold level (Buy)
input double                InpRSIOverbought    = 70.0;         // RSI overbought level (Sell)

input group "=== Break of Structure Entry ==="
input int                   InpBoSLookback      = 50;           // BoS lookback bars
input ENUM_TIMEFRAMES       InpBoSTimeframe     = PERIOD_M15;   // BoS timeframe

input group "=== Money Management ==="
input ENUM_LOT_MODE         InpLotMode          = LOT_FIXED;    // Lot sizing mode
input double                InpFixedLot         = 0.01;         // Fixed starting lot
input double                InpRiskPercent      = 1.0;          // Risk % per starting lot (Dynamic)
input double                InpLotPerBalance    = 1000.0;       // Balance step per fixed lot (Dynamic)
input double                InpMaxLot           = 10.0;         // Max allowed single lot

input group "=== Grid Settings ==="
input int                   InpGridStepPoints   = 250;          // Grid step (points)
input double                InpLotMultiplier    = 1.5;          // Lot multiplier per grid level
input int                   InpMaxOrders        = 8;            // Max orders in the grid (per side)
input bool                  InpUseDynamicStep   = false;        // Widen step with each level
input double                InpStepMultiplier   = 1.0;          // Step multiplier per level (if dynamic)

input group "=== Basket Targets ==="
input ENUM_BASKET_TP_MODE   InpBasketTPMode     = BASKET_TP_MONEY; // Basket TP mode
input double                InpBasketTPPoints   = 150.0;        // Basket TP in avg-price points
input double                InpBasketTPMoney    = 20.0;         // Basket TP in account currency
input double                InpBasketSLMoney    = 0.0;          // Basket SL in account currency (0=off)

input group "=== Risk Protection ==="
input double                InpEquityDDPercent  = 20.0;         // Equity drawdown stop (% of balance)
input bool                  InpHaltAfterStop    = true;         // Halt trading after equity stop
input int                   InpMaxSpreadPoints  = 50;           // Max allowed spread (points)
input int                   InpSlippagePoints   = 30;           // Allowed slippage (points)
input int                   InpMaxRetries       = 5;            // Trade retry attempts on requote
input int                   InpRetryDelayMs     = 250;          // Delay between retries (ms)

input group "=== Dashboard ==="
input bool                  InpShowDashboard    = true;         // Show on-chart dashboard
input color                 InpDashColor        = clrWhite;     // Dashboard text color
input int                   InpDashFontSize     = 9;            // Dashboard font size
input int                   InpDashX            = 10;           // Dashboard X offset
input int                   InpDashY            = 20;           // Dashboard Y offset

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade         g_trade;
CPositionInfo  g_pos;
CSymbolInfo    g_sym;
CAccountInfo   g_acc;

int            g_rsi_handle   = INVALID_HANDLE;
bool           g_trading_halt = false;     // Halt flag (after equity stop)
double         g_session_start_balance = 0.0;
string         g_dash_prefix  = "GPEA_DASH_";

//+------------------------------------------------------------------+
//| Helper: round volume to symbol step                              |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   double minLot  = g_sym.LotsMin();
   double maxLot  = g_sym.LotsMax();
   double stepLot = g_sym.LotsStep();

   if(stepLot <= 0.0) stepLot = 0.01;
   volume = MathFloor(volume / stepLot) * stepLot;

   if(volume < minLot) volume = minLot;
   if(volume > maxLot) volume = maxLot;
   if(volume > InpMaxLot) volume = InpMaxLot;

   return NormalizeDouble(volume, 2);
}

//+------------------------------------------------------------------+
//| Helper: starting lot                                             |
//+------------------------------------------------------------------+
double StartingLot()
{
   double lot = InpFixedLot;
   if(InpLotMode == LOT_DYNAMIC)
   {
      double balance = g_acc.Balance();
      if(InpLotPerBalance > 0.0)
         lot = (balance / InpLotPerBalance) * InpFixedLot;
      // Optional: risk-percent based could be added here based on SL distance
   }
   return NormalizeVolume(lot);
}

//+------------------------------------------------------------------+
//| Helper: convert points to price                                  |
//+------------------------------------------------------------------+
double PointsToPrice(int points)
{
   return points * g_sym.Point();
}

//+------------------------------------------------------------------+
//| Spread check                                                     |
//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   g_sym.RefreshRates();
   int spread = (int)((g_sym.Ask() - g_sym.Bid()) / g_sym.Point());
   return (InpMaxSpreadPoints <= 0 || spread <= InpMaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| Iterate own positions by direction                               |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE type, double &totalLots, double &avgPrice, double &totalProfit)
{
   totalLots   = 0.0;
   avgPrice    = 0.0;
   totalProfit = 0.0;
   int count   = 0;
   double weighted = 0.0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol) continue;
      if(g_pos.Magic() != InpMagic) continue;
      if(g_pos.PositionType() != type) continue;

      double v = g_pos.Volume();
      double p = g_pos.PriceOpen();
      totalLots   += v;
      weighted    += v * p;
      totalProfit += g_pos.Profit() + g_pos.Swap() + g_pos.Commission();
      count++;
   }
   if(totalLots > 0.0) avgPrice = weighted / totalLots;
   return count;
}

//+------------------------------------------------------------------+
//| Sum profit for both sides                                        |
//+------------------------------------------------------------------+
double BasketProfit()
{
   double profit = 0.0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol) continue;
      if(g_pos.Magic() != InpMagic) continue;
      profit += g_pos.Profit() + g_pos.Swap() + g_pos.Commission();
   }
   return profit;
}

//+------------------------------------------------------------------+
//| Find furthest / last grid order for a side                       |
//+------------------------------------------------------------------+
bool LastGridLevel(ENUM_POSITION_TYPE type, double &lastPrice, double &lastVolume)
{
   bool found = false;
   double extremePrice = (type == POSITION_TYPE_BUY) ? DBL_MAX : -DBL_MAX;
   lastVolume = 0.0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol) continue;
      if(g_pos.Magic() != InpMagic) continue;
      if(g_pos.PositionType() != type) continue;

      double p = g_pos.PriceOpen();
      if(type == POSITION_TYPE_BUY)
      {
         if(p < extremePrice)
         {
            extremePrice = p;
            lastVolume   = g_pos.Volume();
            found = true;
         }
      }
      else
      {
         if(p > extremePrice)
         {
            extremePrice = p;
            lastVolume   = g_pos.Volume();
            found = true;
         }
      }
   }
   if(found) lastPrice = extremePrice;
   return found;
}

//+------------------------------------------------------------------+
//| Robust order send with retry                                     |
//+------------------------------------------------------------------+
bool ExecuteMarket(ENUM_POSITION_TYPE type, double volume, const string comment)
{
   for(int attempt = 0; attempt < MathMax(1, InpMaxRetries); attempt++)
   {
      g_sym.RefreshRates();
      double price = (type == POSITION_TYPE_BUY) ? g_sym.Ask() : g_sym.Bid();
      bool ok = false;

      if(type == POSITION_TYPE_BUY)
         ok = g_trade.Buy(volume, _Symbol, price, 0.0, 0.0, comment);
      else
         ok = g_trade.Sell(volume, _Symbol, price, 0.0, 0.0, comment);

      if(ok && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
         return true;

      uint rc = g_trade.ResultRetcode();
      PrintFormat("Trade attempt %d failed: retcode=%u (%s)", attempt + 1, rc, g_trade.ResultRetcodeDescription());

      // Non-retryable conditions
      if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_TRADE_DISABLED ||
         rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_INVALID_VOLUME)
         return false;

      Sleep(InpRetryDelayMs);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close all our positions on this symbol                           |
//+------------------------------------------------------------------+
void CloseAll(const string reason)
{
   PrintFormat("Closing all positions: %s", reason);
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol) continue;
      if(g_pos.Magic() != InpMagic) continue;

      ulong ticket = g_pos.Ticket();
      for(int attempt = 0; attempt < MathMax(1, InpMaxRetries); attempt++)
      {
         if(g_trade.PositionClose(ticket, InpSlippagePoints))
            break;
         Sleep(InpRetryDelayMs);
      }
   }
}

//+------------------------------------------------------------------+
//| RSI signal: returns +1 (Buy), -1 (Sell), 0 (none)                |
//+------------------------------------------------------------------+
int RSISignal()
{
   if(g_rsi_handle == INVALID_HANDLE) return 0;
   double buf[];
   if(CopyBuffer(g_rsi_handle, 0, 0, 2, buf) < 2) return 0;
   double rsi = buf[0]; // current bar / latest value
   if(rsi <= InpRSIOversold)   return +1;
   if(rsi >= InpRSIOverbought) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Break of Structure signal                                        |
//|   Buy:  current Bid > highest high of last N bars                |
//|   Sell: current Ask < lowest  low  of last N bars                |
//+------------------------------------------------------------------+
int BoSSignal()
{
   int bars = MathMax(5, InpBoSLookback);
   double highs[]; double lows[];
   if(CopyHigh(_Symbol, InpBoSTimeframe, 1, bars, highs) < bars) return 0;
   if(CopyLow (_Symbol, InpBoSTimeframe, 1, bars, lows ) < bars) return 0;

   double hh = highs[ArrayMaximum(highs)];
   double ll = lows [ArrayMinimum(lows )];

   g_sym.RefreshRates();
   if(g_sym.Bid() > hh) return +1;
   if(g_sym.Ask() < ll) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Combined entry signal                                            |
//+------------------------------------------------------------------+
int EntrySignal()
{
   int sig = (InpEntryMode == ENTRY_RSI) ? RSISignal() : BoSSignal();
   if(InpDirection == DIR_BUY_ONLY  && sig != +1) return 0;
   if(InpDirection == DIR_SELL_ONLY && sig != -1) return 0;
   return sig;
}

//+------------------------------------------------------------------+
//| Try to open / extend the grid for a side                         |
//+------------------------------------------------------------------+
void HandleSide(ENUM_POSITION_TYPE type, int signal)
{
   double totalLots = 0.0, avgPrice = 0.0, profit = 0.0;
   int countSide = CountPositions(type, totalLots, avgPrice, profit);

   // Open initial position if no exposure and signal aligns with side
   if(countSide == 0)
   {
      bool aligned =
         (type == POSITION_TYPE_BUY  && signal == +1) ||
         (type == POSITION_TYPE_SELL && signal == -1);

      if(!aligned) return;
      if(!IsSpreadOK()) return;

      double lot = StartingLot();
      if(lot <= 0.0) return;
      ExecuteMarket(type, lot, InpComment + " L1");
      return;
   }

   // Grid extension
   if(countSide >= InpMaxOrders) return;
   if(!IsSpreadOK()) return;

   double lastPrice = 0.0, lastVolume = 0.0;
   if(!LastGridLevel(type, lastPrice, lastVolume)) return;

   int level = countSide; // next level index (1-based level = countSide+1)
   double step = InpGridStepPoints;
   if(InpUseDynamicStep && InpStepMultiplier > 1.0)
      step = InpGridStepPoints * MathPow(InpStepMultiplier, level);

   double stepPrice = step * g_sym.Point();
   g_sym.RefreshRates();

   bool trigger = false;
   if(type == POSITION_TYPE_BUY)
      trigger = (g_sym.Ask() <= lastPrice - stepPrice);
   else
      trigger = (g_sym.Bid() >= lastPrice + stepPrice);

   if(!trigger) return;

   double nextLot = NormalizeVolume(lastVolume * InpLotMultiplier);
   if(nextLot <= 0.0) return;

   ExecuteMarket(type, nextLot, StringFormat("%s L%d", InpComment, level + 1));
}

//+------------------------------------------------------------------+
//| Check basket TP/SL                                               |
//+------------------------------------------------------------------+
void CheckBasketTargets()
{
   double buyLots, buyAvg, buyProfit;
   int buys = CountPositions(POSITION_TYPE_BUY, buyLots, buyAvg, buyProfit);
   double sellLots, sellAvg, sellProfit;
   int sells = CountPositions(POSITION_TYPE_SELL, sellLots, sellAvg, sellProfit);

   double total = buyProfit + sellProfit;
   int totalPos = buys + sells;
   if(totalPos == 0) return;

   // Money-based basket SL
   if(InpBasketSLMoney > 0.0 && total <= -InpBasketSLMoney)
   {
      CloseAll("Basket money SL");
      return;
   }

   // Money-based basket TP
   if(InpBasketTPMode == BASKET_TP_MONEY && InpBasketTPMoney > 0.0)
   {
      if(total >= InpBasketTPMoney)
      {
         CloseAll("Basket money TP");
         return;
      }
   }

   // Points-based basket TP (per side, against side avg price)
   if(InpBasketTPMode == BASKET_TP_POINTS && InpBasketTPPoints > 0.0)
   {
      g_sym.RefreshRates();
      double tpDist = InpBasketTPPoints * g_sym.Point();
      bool hitBuy  = (buys  > 0 && g_sym.Bid() >= buyAvg  + tpDist);
      bool hitSell = (sells > 0 && g_sym.Ask() <= sellAvg - tpDist);
      // Close opposite/aligned baskets independently
      if(hitBuy)
         CloseSide(POSITION_TYPE_BUY, "Basket points TP (BUY)");
      if(hitSell)
         CloseSide(POSITION_TYPE_SELL, "Basket points TP (SELL)");
   }
}

//+------------------------------------------------------------------+
//| Close one side only                                              |
//+------------------------------------------------------------------+
void CloseSide(ENUM_POSITION_TYPE type, const string reason)
{
   PrintFormat("Closing side %s: %s", EnumToString(type), reason);
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol) continue;
      if(g_pos.Magic() != InpMagic) continue;
      if(g_pos.PositionType() != type) continue;

      ulong ticket = g_pos.Ticket();
      for(int attempt = 0; attempt < MathMax(1, InpMaxRetries); attempt++)
      {
         if(g_trade.PositionClose(ticket, InpSlippagePoints))
            break;
         Sleep(InpRetryDelayMs);
      }
   }
}

//+------------------------------------------------------------------+
//| Equity protection                                                |
//+------------------------------------------------------------------+
bool CheckEquityProtection()
{
   if(InpEquityDDPercent <= 0.0) return false;

   double balance = g_acc.Balance();
   double equity  = g_acc.Equity();
   double ddPct   = (balance > 0.0) ? (100.0 * (balance - equity) / balance) : 0.0;

   if(ddPct >= InpEquityDDPercent)
   {
      CloseAll(StringFormat("Equity DD stop %.2f%% >= %.2f%%", ddPct, InpEquityDDPercent));
      if(InpHaltAfterStop) g_trading_halt = true;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void DashLabel(const string name, int x, int y, const string text)
{
   string obj = g_dash_prefix + name;
   if(ObjectFind(0, obj) < 0)
   {
      ObjectCreate(0, obj, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, obj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, obj, OBJPROP_COLOR, InpDashColor);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, InpDashFontSize);
      ObjectSetString (0, obj, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, obj, OBJPROP_BACK, false);
   }
   ObjectSetString(0, obj, OBJPROP_TEXT, text);
}

void RemoveDashboard()
{
   ObjectsDeleteAll(0, g_dash_prefix);
}

void UpdateDashboard()
{
   if(!InpShowDashboard) return;

   double buyLots, buyAvg, buyProfit;
   int buys  = CountPositions(POSITION_TYPE_BUY, buyLots, buyAvg, buyProfit);
   double sellLots, sellAvg, sellProfit;
   int sells = CountPositions(POSITION_TYPE_SELL, sellLots, sellAvg, sellProfit);
   double basket = buyProfit + sellProfit;

   g_sym.RefreshRates();
   int spread = (int)((g_sym.Ask() - g_sym.Bid()) / g_sym.Point());

   double balance = g_acc.Balance();
   double equity  = g_acc.Equity();
   double ddPct   = (balance > 0.0) ? (100.0 * (balance - equity) / balance) : 0.0;

   string status = g_trading_halt ? "HALTED (equity stop)" :
                   (IsSpreadOK() ? "Active" : "Blocked (spread)");

   int row = 0;
   int dy  = InpDashFontSize + 6;

   DashLabel("title", InpDashX, InpDashY + dy * row++, "=== GridProEA Dashboard ===");
   DashLabel("status",InpDashX, InpDashY + dy * row++, StringFormat("Status: %s", status));
   DashLabel("symbol",InpDashX, InpDashY + dy * row++, StringFormat("Symbol: %s   Spread: %d pt (max %d)",
                                                       _Symbol, spread, InpMaxSpreadPoints));
   DashLabel("acc",   InpDashX, InpDashY + dy * row++, StringFormat("Balance: %.2f   Equity: %.2f   DD: %.2f%%",
                                                       balance, equity, ddPct));
   DashLabel("buy",   InpDashX, InpDashY + dy * row++, StringFormat("BUY  orders: %d  lots: %.2f  avg: %.5f  P/L: %.2f",
                                                       buys, buyLots, buyAvg, buyProfit));
   DashLabel("sell",  InpDashX, InpDashY + dy * row++, StringFormat("SELL orders: %d  lots: %.2f  avg: %.5f  P/L: %.2f",
                                                       sells, sellLots, sellAvg, sellProfit));
   DashLabel("basket",InpDashX, InpDashY + dy * row++, StringFormat("Basket P/L: %.2f", basket));
   DashLabel("cfg",   InpDashX, InpDashY + dy * row++, StringFormat("Step: %d pt   Mult: %.2f   Max: %d   Magic: %I64d",
                                                       InpGridStepPoints, InpLotMultiplier, InpMaxOrders, InpMagic));
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!g_sym.Name(_Symbol))
   {
      Print("Failed to select symbol info for ", _Symbol);
      return INIT_FAILED;
   }
   g_sym.RefreshRates();

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   g_rsi_handle = iRSI(_Symbol, InpRSITimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(g_rsi_handle == INVALID_HANDLE)
   {
      Print("Failed to create RSI handle");
      return INIT_FAILED;
   }

   g_session_start_balance = g_acc.Balance();
   g_trading_halt = false;

   if(InpShowDashboard) UpdateDashboard();

   PrintFormat("GridProEA initialized on %s. Magic=%I64d", _Symbol, InpMagic);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_rsi_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_rsi_handle);
      g_rsi_handle = INVALID_HANDLE;
   }
   RemoveDashboard();
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   g_sym.RefreshRates();

   // 1) Equity hard-stop (always first)
   if(CheckEquityProtection())
   {
      if(InpShowDashboard) UpdateDashboard();
      return;
   }

   if(g_trading_halt)
   {
      // Manage existing positions only via basket targets; do not open new
      CheckBasketTargets();
      if(InpShowDashboard) UpdateDashboard();
      return;
   }

   // 2) Basket TP / SL management
   CheckBasketTargets();

   // 3) Entry / grid extension
   int signal = EntrySignal();

   if(InpDirection == DIR_BUY_ONLY || InpDirection == DIR_BOTH)
      HandleSide(POSITION_TYPE_BUY, signal);

   if(InpDirection == DIR_SELL_ONLY || InpDirection == DIR_BOTH)
      HandleSide(POSITION_TYPE_SELL, signal);

   // 4) UI refresh
   if(InpShowDashboard) UpdateDashboard();
}

//+------------------------------------------------------------------+
//| OnTradeTransaction (kept for future fine-grained event handling) |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   // Reserved for future expansion (e.g. logging fills, reacting to closes).
}
//+------------------------------------------------------------------+
