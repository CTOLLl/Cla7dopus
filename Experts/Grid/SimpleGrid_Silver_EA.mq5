//+------------------------------------------------------------------+
//|                                       SimpleGrid_Silver_EA.mq5   |
//|        Simple dual-direction grid EA tuned for XAGUSD (Silver).  |
//|        Defaults assume 3-digit silver quotes (1 point = 0.001).  |
//+------------------------------------------------------------------+
#property copyright   "Tembo Algotrading"
#property version     "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

// --- Defaults tuned for XAGUSD ---
// Step 800 points = $0.80 on a 3-digit broker (point=0.001).
// Silver is more volatile %-wise than gold — slightly fewer levels,
// smaller multiplier to limit drawdown explosion.
input long   InpMagic       = 20260604;   // Magic number
input double InpLot          = 0.01;      // First lot
input double InpLotMult      = 1.4;       // Lot multiplier per level
input int    InpStepPoints   = 800;       // Grid step (points) ~ $0.80 for 3-digit silver
input int    InpMaxLevels    = 6;         // Max levels per direction
input double InpTpMoney      = 5.0;       // Take profit per basket (account currency)
input int    InpSlippage     = 30;        // Slippage (points)
input int    InpMaxSpreadPts = 120;       // Skip new entries if spread exceeds (points)

CTrade        Trade;
CPositionInfo Pos;
CSymbolInfo   Sym;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!Sym.Name(_Symbol)) return INIT_FAILED;
   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints((ulong)InpSlippage);
   Trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void Scan(ENUM_POSITION_TYPE dir, int &cnt, double &profit,
          double &bestPrice, double &worstPrice)
  {
   cnt = 0; profit = 0.0;
   bestPrice = 0.0;
   worstPrice = (dir == POSITION_TYPE_BUY) ? DBL_MAX : 0.0;

   for(int i = PositionsTotal()-1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != InpMagic) continue;
      if(Pos.PositionType() != dir) continue;

      cnt++;
      profit += Pos.Profit() + Pos.Swap() + Pos.Commission();
      double p = Pos.PriceOpen();

      if(dir == POSITION_TYPE_BUY)
        {
         if(p > bestPrice)  bestPrice  = p;
         if(p < worstPrice) worstPrice = p;
        }
      else
        {
         if(p > worstPrice) worstPrice = p;
         if(bestPrice == 0.0 || p < bestPrice) bestPrice = p;
        }
     }
   if(dir == POSITION_TYPE_BUY && worstPrice == DBL_MAX) worstPrice = 0.0;
  }

//+------------------------------------------------------------------+
void CloseDirection(ENUM_POSITION_TYPE dir)
  {
   for(int i = PositionsTotal()-1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != InpMagic) continue;
      if(Pos.PositionType() != dir) continue;
      Trade.PositionClose(Pos.Ticket(), (ulong)InpSlippage);
     }
  }

//+------------------------------------------------------------------+
double NextLot(int currentLevels)
  {
   double lot = InpLot * MathPow(MathMax(1.0, InpLotMult), currentLevels);
   double step = Sym.LotsStep();
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   if(lot < Sym.LotsMin()) lot = Sym.LotsMin();
   if(lot > Sym.LotsMax()) lot = Sym.LotsMax();
   return NormalizeDouble(lot, 2);
  }

//+------------------------------------------------------------------+
double SpreadPoints()
  {
   return (Sym.Ask() - Sym.Bid()) / Sym.Point();
  }

//+------------------------------------------------------------------+
void ManageSide(ENUM_POSITION_TYPE dir)
  {
   int    cnt = 0;
   double profit = 0.0, bestPrice = 0.0, worstPrice = 0.0;
   Scan(dir, cnt, profit, bestPrice, worstPrice);

   if(cnt > 0 && profit >= InpTpMoney)
     {
      CloseDirection(dir);
      return;
     }

   if(cnt >= InpMaxLevels) return;
   if(SpreadPoints() > InpMaxSpreadPts) return;

   double stepPrice = InpStepPoints * Sym.Point();
   Sym.RefreshRates();

   if(cnt == 0)
     {
      double lot = NextLot(0);
      if(dir == POSITION_TYPE_BUY)
         Trade.Buy(lot, _Symbol, Sym.Ask(), 0, 0, "SimpleGridSilver");
      else
         Trade.Sell(lot, _Symbol, Sym.Bid(), 0, 0, "SimpleGridSilver");
      return;
     }

   bool addNow = false;
   if(dir == POSITION_TYPE_BUY)
      addNow = (Sym.Ask() <= worstPrice - stepPrice);
   else
      addNow = (Sym.Bid() >= worstPrice + stepPrice);

   if(addNow)
     {
      double lot = NextLot(cnt);
      if(dir == POSITION_TYPE_BUY)
         Trade.Buy(lot, _Symbol, Sym.Ask(), 0, 0, "SimpleGridSilver");
      else
         Trade.Sell(lot, _Symbol, Sym.Bid(), 0, 0, "SimpleGridSilver");
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!Sym.RefreshRates()) return;
   ManageSide(POSITION_TYPE_BUY);
   ManageSide(POSITION_TYPE_SELL);
  }
//+------------------------------------------------------------------+
