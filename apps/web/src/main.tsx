import "@fontsource/newsreader/500.css";
import "@fontsource/newsreader/600-italic.css";
import "@fontsource/ibm-plex-sans/400.css";
import "@fontsource/ibm-plex-sans/500.css";
import "@fontsource/ibm-plex-sans/600.css";
import "@fontsource/ibm-plex-mono/400.css";
import "@fontsource/ibm-plex-mono/500.css";
import "./app.css";

import { lazy, StrictMode, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { createBrowserRouter, Navigate, RouterProvider } from "react-router-dom";
import { Shell } from "./components/Shell";
import { PlanProvider } from "./state/plan";

const AgeOfMoneyPage = lazy(() => import("./pages/AgeOfMoney").then((module) => ({ default: module.AgeOfMoneyPage })));
const ApiDocsPage = lazy(() => import("./pages/ApiDocs").then((module) => ({ default: module.ApiDocsPage })));
const ApiTokensPage = lazy(() => import("./pages/ApiTokens").then((module) => ({ default: module.ApiTokensPage })));
const IncomePage = lazy(() => import("./pages/Income").then((module) => ({ default: module.IncomePage })));
const NetWorthPage = lazy(() => import("./pages/NetWorth").then((module) => ({ default: module.NetWorthPage })));
const QuickEntryPage = lazy(() => import("./pages/QuickEntry").then((module) => ({ default: module.QuickEntryPage })));
const RewardsImportPage = lazy(() => import("./pages/RewardsImport").then((module) => ({ default: module.RewardsImportPage })));
const ScheduledTransactionsPage = lazy(() => import("./pages/ScheduledTransactions").then((module) => ({ default: module.ScheduledTransactionsPage })));
const SpendingPage = lazy(() => import("./pages/Spending").then((module) => ({ default: module.SpendingPage })));
const TransactionsPage = lazy(() => import("./pages/Transactions").then((module) => ({ default: module.TransactionsPage })));

function RouteFallback() {
  return <div className="boot-message">Loading…</div>;
}

const home = "/transactions?range=all&accounts=all";

const router = createBrowserRouter([
  {
    element: <PlanProvider><Shell /></PlanProvider>,
    children: [
      { path: "/", element: <Navigate to={home} replace /> },
      { path: "/scheduled", element: <ScheduledTransactionsPage /> },
      { path: "/api-tokens", element: <ApiTokensPage /> },
      { path: "/import/rewards", element: <RewardsImportPage /> },
      { path: "/spending", element: <SpendingPage /> },
      { path: "/income", element: <IncomePage /> },
      { path: "/net-worth", element: <NetWorthPage /> },
      { path: "/age-of-money", element: <AgeOfMoneyPage /> },
      { path: "/transactions", element: <TransactionsPage /> },
      { path: "*", element: <Navigate to={home} replace /> },
    ],
  },
  { path: "/add", element: <PlanProvider><Suspense fallback={<RouteFallback />}><QuickEntryPage /></Suspense></PlanProvider> },
  { path: "/docs", element: <ApiDocsPage /> },
]);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Suspense fallback={<RouteFallback />}>
      <RouterProvider router={router} />
    </Suspense>
  </StrictMode>,
);
