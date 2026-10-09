import { Navigate, Route, Routes } from "react-router";
import { AuthWatcher, RequireAuth } from "./auth";
import { Layout } from "./components/Layout";
import EngagementPage from "./pages/EngagementPage";
import FleetPage from "./pages/FleetPage";
import InstallDetailPage from "./pages/InstallDetailPage";
import InstallsPage from "./pages/InstallsPage";
import LoginPage from "./pages/LoginPage";
import OverviewPage from "./pages/OverviewPage";
import ReliabilityPage from "./pages/ReliabilityPage";

export default function App() {
  return (
    <>
      <AuthWatcher />
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route
          element={
            <RequireAuth>
              <Layout />
            </RequireAuth>
          }
        >
          <Route index element={<OverviewPage />} />
          <Route path="installs" element={<InstallsPage />} />
          <Route path="installs/:hash" element={<InstallDetailPage />} />
          <Route path="engagement" element={<EngagementPage />} />
          <Route path="reliability" element={<ReliabilityPage />} />
          <Route path="fleet" element={<FleetPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Route>
      </Routes>
    </>
  );
}
