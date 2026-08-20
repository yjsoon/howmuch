import "@fontsource/newsreader/500.css";
import "@fontsource/newsreader/600-italic.css";
import "@fontsource/ibm-plex-sans/400.css";
import "@fontsource/ibm-plex-sans/500.css";
import "@fontsource/ibm-plex-sans/600.css";
import "@fontsource/ibm-plex-mono/400.css";
import "@fontsource/ibm-plex-mono/500.css";
import "./app.css";

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createBrowserRouter, Navigate, RouterProvider } from "react-router-dom";
import { Shell } from "./components/Shell";
import { AgeOfMoneyPage } from "./pages/AgeOfMoney";
import { IncomePage } from "./pages/Income";
import { NetWorthPage } from "./pages/NetWorth";
import { PlanPage } from "./pages/Plan";
import { QuickEntryPage } from "./pages/QuickEntry";
import { ScheduledTransactionsPage } from "./pages/ScheduledTransactions";
import { SpendingPage } from "./pages/Spending";
import { TransactionsPage } from "./pages/Transactions";
import { PlanProvider } from "./state/plan";

const router = createBrowserRouter([
  {
    element: <PlanProvider><Shell /></PlanProvider>,
    children: [
      { path: "/", element: <Navigate to="/plan" replace /> },
      { path: "/plan", element: <PlanPage /> },
      { path: "/scheduled", element: <ScheduledTransactionsPage /> },
      { path: "/spending", element: <SpendingPage /> },
      { path: "/income", element: <IncomePage /> },
      { path: "/net-worth", element: <NetWorthPage /> },
      { path: "/age-of-money", element: <AgeOfMoneyPage /> },
      { path: "/transactions", element: <TransactionsPage /> },
      { path: "*", element: <Navigate to="/plan" replace /> },
    ],
  },
  { path: "/add", element: <PlanProvider><QuickEntryPage /></PlanProvider> },
]);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>,
);
