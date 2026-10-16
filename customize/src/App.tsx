import { type ReactNode } from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import { AppShell } from "@/components/app-shell";
import { useAuth } from "@/contexts/auth-context";
import { LoginPage } from "@/pages/login";
import { EnterprisesPage } from "@/pages/enterprises";
import { HubPage } from "@/pages/hub";
import { CustomizationsPage } from "@/pages/customizations";
import { OeeProfilePage } from "@/pages/oee-profile";
import { IntegrationsPage } from "@/pages/integrations";
import { NodeRedPage } from "@/pages/node-red";
import { PlcConnectionsPage } from "@/pages/plc-connections";

function ProtectedRoute({ children }: { children: ReactNode }) {
  const { isAuthenticated, isLoading } = useAuth();
  if (isLoading) return null;
  if (!isAuthenticated) return <Navigate to="/login" replace />;
  return children;
}

function PublicRoute({ children }: { children: ReactNode }) {
  const { isAuthenticated, isLoading } = useAuth();
  if (isLoading) return null;
  if (isAuthenticated) return <Navigate to="/enterprises" replace />;
  return children;
}

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<Navigate to="/login" replace />} />
      <Route path="/login" element={<PublicRoute><LoginPage /></PublicRoute>} />

      <Route
        path="/enterprises"
        element={<ProtectedRoute><EnterprisesPage /></ProtectedRoute>}
      />

      <Route path="/app" element={<ProtectedRoute><AppShell /></ProtectedRoute>}>
        <Route index element={<Navigate to="/app/hub" replace />} />
        <Route path="hub" element={<HubPage />} />
        <Route path="customizations" element={<CustomizationsPage />} />
        <Route path="oee-profile" element={<OeeProfilePage />} />
        <Route path="integrations" element={<IntegrationsPage />} />
        <Route path="node-red" element={<NodeRedPage />} />
        <Route path="plc-connections" element={<PlcConnectionsPage />} />
      </Route>

      <Route path="*" element={<Navigate to="/login" replace />} />
    </Routes>
  );
}
