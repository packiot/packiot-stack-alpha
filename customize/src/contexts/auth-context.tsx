import {
  browserLocalPersistence,
  onIdTokenChanged,
  setPersistence,
  signInWithEmailAndPassword,
  signOut as firebaseSignOut,
  type User,
} from "firebase/auth";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { auth } from "@/lib/firebase";
import {
  COGNITO_ENABLED,
  cognitoSignIn,
  cognitoSignOut,
  getCognitoSession,
} from "@/lib/cognito";

/**
 * A minimal, provider-agnostic identity surface. When the Cognito path is off
 * (the default), `user` mirrors the Firebase User's email and everything behaves
 * exactly as before. When Cognito is enabled, `user` is a small shim carrying
 * the email so the shell's avatar keeps working — routing only depends on
 * `isAuthenticated`. See lib/cognito.ts + lib/auth-token.ts for the dual-path
 * rationale (ADR-0033/0034).
 */
type Identity = { email: string | null };

type AuthContextValue = {
  user: Identity | null;
  userToken: string | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  signIn: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
};

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<Identity | null>(null);
  const [userToken, setUserToken] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    // ── Cognito path (flag-gated, additive) ──────────────────────────────────
    // Hydrate from any existing Amplify session. Amplify persists the session in
    // storage, so a reload restores auth without a fresh sign-in.
    if (COGNITO_ENABLED) {
      let active = true;
      getCognitoSession()
        .then((session) => {
          if (!active) return;
          setUser(session ? { email: session.email ?? null } : null);
          setUserToken(session?.idToken ?? null);
        })
        .finally(() => {
          if (active) setIsLoading(false);
        });
      return () => {
        active = false;
      };
    }

    // ── Firebase path (default — unchanged) ──────────────────────────────────
    return onIdTokenChanged(auth, async (nextUser: User | null) => {
      if (!nextUser) {
        setUser(null);
        setUserToken(null);
        setIsLoading(false);
        return;
      }
      const token = await nextUser.getIdToken();
      setUser({ email: nextUser.email });
      setUserToken(token);
      setIsLoading(false);
    });
  }, []);

  const signIn = useCallback(async (email: string, password: string) => {
    if (COGNITO_ENABLED) {
      await cognitoSignIn(email, password);
      const session = await getCognitoSession();
      setUser(session ? { email: session.email ?? email } : { email });
      setUserToken(session?.idToken ?? null);
      return;
    }
    await setPersistence(auth, browserLocalPersistence);
    await signInWithEmailAndPassword(auth, email, password);
  }, []);

  const signOut = useCallback(async () => {
    if (COGNITO_ENABLED) {
      await cognitoSignOut();
      setUser(null);
      setUserToken(null);
      return;
    }
    await firebaseSignOut(auth);
  }, []);

  const value = useMemo<AuthContextValue>(
    () => ({
      user,
      userToken,
      isAuthenticated: Boolean(userToken),
      isLoading,
      signIn,
      signOut,
    }),
    [isLoading, signIn, signOut, user, userToken]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) throw new Error("useAuth must be used within an AuthProvider");
  return context;
}
