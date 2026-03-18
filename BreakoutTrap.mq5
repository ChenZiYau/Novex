//+------------------------------------------------------------------+
//|                                                BreakoutTrap.mq5  |
//|                        Breakout Straddle EA for XAUUSD M1        |
//|                                                                  |
//|  Strategy: Places symmetric Buy Stop / Sell Stop pending orders  |
//|  around the current price to "trap" breakouts. Manages open      |
//|  positions via trailing stop and global basket profit target.     |
//+------------------------------------------------------------------+
#property copyright "BreakoutTrap EA"
#property link      ""
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//|                       INPUT PARAMETERS                           |
//+------------------------------------------------------------------+

input double   LotSize                  = 0.02;    // Starting lot size
input int      Distance_Pips            = 15;      // Distance from price for pending orders (in pips)
input int      StopLoss_Pips            = 10;      // Hard stop-loss for each order (in pips)
input bool     Use_Trailing_Stop        = true;    // Enable tick-based trailing stop
input int      Trailing_Activation_Pips = 20;      // Profit pips before trailing activates
input int      Trailing_Distance_Pips   = 10;      // Trail distance behind price (in pips)
input double   Global_Profit_Target     = 50.0;    // Close all if total profit >= this ($)
input bool     Delete_Opposite_Order    = false;   // Delete opposite pending when one triggers
input int      MagicNumber              = 123456;  // Unique identifier for this EA's orders
input bool     Use_Lot_Multiplier       = false;   // Multiply lot after SL hit (martingale)
input double   Lot_Multiplier           = 1.5;     // Multiplier factor after a loss
input double   Max_Lot_Size             = 0.10;    // Maximum lot cap for multiplier safety

//+------------------------------------------------------------------+
//|                       GLOBAL VARIABLES                           |
//+------------------------------------------------------------------+

CTrade         trade;                              // Trade execution object
double         g_point;                            // Symbol point value
int            g_digits;                           // Symbol decimal digits
double         g_pipValue;                         // Calculated pip value (points per pip)
double         g_currentLot;                       // Active lot size (may change with multiplier)
bool           g_lastTradeLoss = false;            // Tracks if previous trade was a loss

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // --- Validate symbol ---
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE))
   {
      Print("ERROR: Symbol ", _Symbol, " is not available for trading.");
      return INIT_FAILED;
   }

   // --- Cache symbol properties ---
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // --- Calculate pip value ---
   // For 5-digit brokers (EURUSD etc.) 1 pip = 10 points
   // For 3-digit brokers (XAUUSD etc.) 1 pip = 10 points
   // For 2/4-digit brokers, 1 pip = 1 point
   if(g_digits == 3 || g_digits == 5)
      g_pipValue = g_point * 10;
   else
      g_pipValue = g_point;

   // --- Configure trade object ---
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);  // Max slippage tolerance: 10 points
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // --- Initialize lot size ---
   g_currentLot = LotSize;

   Print("BreakoutTrap EA initialized on ", _Symbol,
         " | Point=", g_point,
         " | PipValue=", g_pipValue,
         " | Digits=", g_digits);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up: remove all pending orders placed by this EA
   DeleteAllPendingOrders();
   Print("BreakoutTrap EA removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function — main execution loop                       |
//+------------------------------------------------------------------+
void OnTick()
{
   // ----------------------------------------------------------
   // STEP 1: Check global basket profit target (safety net)
   // ----------------------------------------------------------
   if(CheckGlobalProfitTarget())
      return;  // All positions closed, pending orders deleted

   // ----------------------------------------------------------
   // STEP 2: Manage trailing stop on any open positions
   // ----------------------------------------------------------
   if(Use_Trailing_Stop)
      ManageTrailingStop();

   // ----------------------------------------------------------
   // STEP 3: Handle opposite order deletion when a pending triggers
   // ----------------------------------------------------------
   if(Delete_Opposite_Order)
      HandleOppositeOrderDeletion();

   // ----------------------------------------------------------
   // STEP 4: Place new trap if no pending orders and no positions
   // ----------------------------------------------------------
   if(CountOwnPendingOrders() == 0 && CountOwnPositions() == 0)
   {
      // Check if previous trade was a loss for lot multiplier
      UpdateLotSize();
      PlaceTrap();
   }

   // ----------------------------------------------------------
   // STEP 5: Re-place trap after a stop-out (position closed,
   //         but we still have a dangling opposite pending)
   //         If Delete_Opposite_Order is false, the other side
   //         stays alive, so only re-trap when fully empty.
   // ----------------------------------------------------------
}

//+------------------------------------------------------------------+
//| Place the breakout trap: Buy Stop + Sell Stop                    |
//+------------------------------------------------------------------+
void PlaceTrap()
{
   // --- Refresh quotes ---
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("ERROR: Failed to get tick data for ", _Symbol);
      return;
   }

   double ask = tick.ask;
   double bid = tick.bid;

   // --- Validate quotes ---
   if(ask <= 0 || bid <= 0)
   {
      Print("ERROR: Invalid price quotes. Ask=", ask, " Bid=", bid);
      return;
   }

   // --- Calculate order levels ---
   double distancePrice = Distance_Pips * g_pipValue;
   double slPrice       = StopLoss_Pips * g_pipValue;

   double buyStopPrice  = NormalizeDouble(ask + distancePrice, g_digits);
   double buyStopSL     = NormalizeDouble(buyStopPrice - slPrice, g_digits);

   double sellStopPrice = NormalizeDouble(bid - distancePrice, g_digits);
   double sellStopSL    = NormalizeDouble(sellStopPrice + slPrice, g_digits);

   // --- Validate margin before placing orders ---
   double marginRequired = 0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, g_currentLot, ask, marginRequired))
   {
      Print("ERROR: Cannot calculate margin.");
      return;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(marginRequired > freeMargin * 0.8)  // Keep 20% buffer
   {
      Print("WARNING: Insufficient free margin. Required=", marginRequired,
            " Available=", freeMargin);
      return;
   }

   // --- Validate lot size against broker limits ---
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(g_currentLot < minLot)
   {
      Print("WARNING: Lot ", g_currentLot, " below minimum ", minLot, ". Adjusting.");
      g_currentLot = minLot;
   }
   if(g_currentLot > maxLot)
   {
      Print("WARNING: Lot ", g_currentLot, " above maximum ", maxLot, ". Capping.");
      g_currentLot = maxLot;
   }

   // Normalize to lot step
   g_currentLot = MathFloor(g_currentLot / lotStep) * lotStep;
   g_currentLot = NormalizeDouble(g_currentLot, 2);

   // --- Validate stop levels (minimum distance from current price) ---
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopLevel * g_point;

   if(distancePrice < minStopDistance)
   {
      Print("WARNING: Distance_Pips too small. Minimum stop distance=",
            minStopDistance / g_pipValue, " pips");
      return;
   }

   // --- Place BUY STOP ---
   if(!trade.BuyStop(g_currentLot, buyStopPrice, _Symbol, buyStopSL, 0, ORDER_TIME_GTC, 0,
                     "BreakoutTrap BuyStop"))
   {
      Print("ERROR: BuyStop placement failed. Code=", trade.ResultRetcode(),
            " Desc=", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("BUY STOP placed: Price=", buyStopPrice, " SL=", buyStopSL,
            " Lot=", g_currentLot);
   }

   // --- Place SELL STOP ---
   if(!trade.SellStop(g_currentLot, sellStopPrice, _Symbol, sellStopSL, 0, ORDER_TIME_GTC, 0,
                      "BreakoutTrap SellStop"))
   {
      Print("ERROR: SellStop placement failed. Code=", trade.ResultRetcode(),
            " Desc=", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("SELL STOP placed: Price=", sellStopPrice, " SL=", sellStopSL,
            " Lot=", g_currentLot);
   }
}

//+------------------------------------------------------------------+
//| Trailing Stop Management — tick-based                            |
//|                                                                  |
//| Logic: Once an open position is in profit by Activation_Pips,    |
//| move the SL to lock in profit, trailing behind price by          |
//| Trailing_Distance_Pips. Only moves SL in the favorable direction |
//| (never widens the stop).                                         |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double activationDistance = Trailing_Activation_Pips * g_pipValue;
   double trailDistance      = Trailing_Distance_Pips * g_pipValue;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0) continue;

      // --- Only manage our own positions ---
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double posType    = PositionGetInteger(POSITION_TYPE);

      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) continue;

      if(posType == POSITION_TYPE_BUY)
      {
         double profit = tick.bid - openPrice;

         // --- Check if activation threshold is met ---
         if(profit >= activationDistance)
         {
            // New SL trails behind current bid by trailDistance
            double newSL = NormalizeDouble(tick.bid - trailDistance, g_digits);

            // Only move SL up (tighter), never down (wider)
            if(newSL > currentSL || currentSL == 0)
            {
               if(!trade.PositionModify(posTicket, newSL, 0))
               {
                  Print("ERROR: Trailing SL modify failed for BUY #", posTicket,
                        " Code=", trade.ResultRetcode());
               }
               else
               {
                  Print("TRAIL BUY #", posTicket, ": SL moved to ", newSL);
               }
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double profit = openPrice - tick.ask;

         // --- Check if activation threshold is met ---
         if(profit >= activationDistance)
         {
            // New SL trails above current ask by trailDistance
            double newSL = NormalizeDouble(tick.ask + trailDistance, g_digits);

            // Only move SL down (tighter), never up (wider)
            if(newSL < currentSL || currentSL == 0)
            {
               if(!trade.PositionModify(posTicket, newSL, 0))
               {
                  Print("ERROR: Trailing SL modify failed for SELL #", posTicket,
                        " Code=", trade.ResultRetcode());
               }
               else
               {
                  Print("TRAIL SELL #", posTicket, ": SL moved to ", newSL);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Global Basket Profit Target Check                                |
//|                                                                  |
//| If total floating profit across all EA positions reaches the     |
//| target, close everything and delete all pending orders.          |
//+------------------------------------------------------------------+
bool CheckGlobalProfitTarget()
{
   double totalProfit = 0;
   int posCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0) continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP);
      posCount++;
   }

   if(posCount > 0 && totalProfit >= Global_Profit_Target)
   {
      Print("*** GLOBAL PROFIT TARGET HIT: $", totalProfit, " >= $", Global_Profit_Target,
            " — Closing all positions ***");

      // --- Close all positions ---
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong posTicket = PositionGetTicket(i);
         if(posTicket == 0) continue;

         if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         if(!trade.PositionClose(posTicket, 10))  // 10 points slippage
         {
            Print("ERROR: Failed to close position #", posTicket,
                  " Code=", trade.ResultRetcode());
         }
         else
         {
            Print("Closed position #", posTicket, " for global profit target.");
            g_lastTradeLoss = false;  // Profitable exit
         }
      }

      // --- Delete all pending orders ---
      DeleteAllPendingOrders();
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Handle deletion of opposite pending order when one triggers      |
//|                                                                  |
//| If Delete_Opposite_Order is true and we have an open position    |
//| plus a remaining pending order, delete the pending order.        |
//+------------------------------------------------------------------+
void HandleOppositeOrderDeletion()
{
   // Only act if we have at least one open position
   if(CountOwnPositions() == 0) return;

   // Delete any remaining pending orders belonging to this EA
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket == 0) continue;

      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      long orderType = OrderGetInteger(ORDER_TYPE);
      if(orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP)
      {
         if(!trade.OrderDelete(orderTicket))
         {
            Print("ERROR: Failed to delete opposite order #", orderTicket,
                  " Code=", trade.ResultRetcode());
         }
         else
         {
            Print("Deleted opposite pending order #", orderTicket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Update lot size based on martingale multiplier logic              |
//+------------------------------------------------------------------+
void UpdateLotSize()
{
   if(!Use_Lot_Multiplier)
   {
      g_currentLot = LotSize;
      return;
   }

   // --- Check deal history for last trade result ---
   if(!CheckLastTradeResult())
   {
      g_currentLot = LotSize;
      return;
   }

   if(g_lastTradeLoss)
   {
      // Multiply lot after a loss
      g_currentLot = NormalizeDouble(g_currentLot * Lot_Multiplier, 2);

      // Cap at maximum
      if(g_currentLot > Max_Lot_Size)
      {
         Print("Lot multiplier capped at Max_Lot_Size: ", Max_Lot_Size);
         g_currentLot = Max_Lot_Size;
      }

      Print("LOT MULTIPLIER: Previous trade was a loss. New lot=", g_currentLot);
   }
   else
   {
      // Reset to base lot after a win
      g_currentLot = LotSize;
   }
}

//+------------------------------------------------------------------+
//| Check the result of the last closed trade for this EA            |
//| Returns true if history was successfully read                    |
//+------------------------------------------------------------------+
bool CheckLastTradeResult()
{
   // Request last 24 hours of deal history
   datetime fromTime = TimeCurrent() - 86400;
   datetime toTime   = TimeCurrent();

   if(!HistorySelect(fromTime, toTime))
   {
      Print("WARNING: Cannot select trade history.");
      return false;
   }

   // Walk backward through deals to find our last closed trade
   int totalDeals = HistoryDealsTotal();
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;

      long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

      // We only care about exit deals (DEAL_ENTRY_OUT)
      if(dealEntry == DEAL_ENTRY_OUT)
      {
         double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                           + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                           + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

         g_lastTradeLoss = (dealProfit < 0);
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Count pending orders belonging to this EA                        |
//+------------------------------------------------------------------+
int CountOwnPendingOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket == 0) continue;

      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count open positions belonging to this EA                        |
//+------------------------------------------------------------------+
int CountOwnPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0) continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Delete all pending orders belonging to this EA                   |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket == 0) continue;

      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      if(!trade.OrderDelete(orderTicket))
      {
         Print("ERROR: Failed to delete pending order #", orderTicket,
               " Code=", trade.ResultRetcode());
      }
      else
      {
         Print("Deleted pending order #", orderTicket);
      }
   }
}

//+------------------------------------------------------------------+
//| OnTradeTransaction — detect when pending orders trigger or       |
//| positions close so we can react immediately                      |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // --- Detect when a pending order is activated (becomes a position) ---
   if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      // An order was removed — could be triggered or manually deleted
      // The OnTick loop will handle re-evaluation
   }

   // --- Detect deal additions (position opened or closed) ---
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      if(dealTicket > 0)
      {
         if(HistoryDealSelect(dealTicket))
         {
            long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
            long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

            if(dealMagic == MagicNumber)
            {
               if(dealEntry == DEAL_ENTRY_IN)
               {
                  Print("EVENT: Pending order triggered. Deal #", dealTicket);
               }
               else if(dealEntry == DEAL_ENTRY_OUT)
               {
                  double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
                  Print("EVENT: Position closed. Deal #", dealTicket,
                        " Profit=", profit);

                  // Track loss for lot multiplier
                  if(profit < 0)
                     g_lastTradeLoss = true;
                  else
                     g_lastTradeLoss = false;
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
