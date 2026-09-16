import { useState, type FormEvent } from "react";
import { useNavigate } from "react-router-dom";
import { toast } from "sonner";
import { Button, Card, Input } from "@/components/ui";
import { useAuth } from "@/contexts/auth-context";

export function LoginPage() {
  const navigate = useNavigate();
  const { signIn } = useAuth();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setSubmitting(true);
    try {
      await signIn(email, password);
      navigate("/enterprises", { replace: true });
    } catch {
      toast.error("Authentication failed. Check your credentials and try again.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <main className="flex min-h-svh items-center justify-center bg-chrome p-6">
      <Card className="w-[404px] overflow-hidden shadow-[0_12px_40px_rgba(0,0,0,0.35)]">
        <div className="flex items-center gap-3 bg-chrome px-7 py-[22px]">
          <img src="/packiot-logo.svg" alt="PackIOT" className="h-5 w-auto" />
          <span className="h-5 w-px bg-white/20" />
          <span className="flex items-center gap-1.5 text-sm font-bold text-white">
            <span className="flex h-5 w-5 items-center justify-center rounded-[5px] bg-primary text-[11px]">✦</span>
            Customization Hub
          </span>
        </div>
        <form onSubmit={handleSubmit} className="px-7 pb-8 pt-[30px]">
          <h1 className="mb-1 text-2xl font-black tracking-tight text-foreground">Welcome back</h1>
          <p className="mb-6 text-sm text-muted-foreground">Sign in to the Packiot Customization Hub.</p>
          <label className="mb-1.5 block text-[11px] font-bold uppercase tracking-[0.04em] text-muted-foreground">Email</label>
          <Input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@packiot.com" className="mb-4" />
          <label className="mb-1.5 block text-[11px] font-bold uppercase tracking-[0.04em] text-muted-foreground">Password</label>
          <Input type="password" required value={password} onChange={(e) => setPassword(e.target.value)} placeholder="••••••••" className="mb-6" />
          <Button type="submit" disabled={submitting} className="w-full">
            {submitting ? "Signing in…" : "Sign in"}
          </Button>
        </form>
      </Card>
    </main>
  );
}
