import path from "node:path";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

// Mirrors csadmin/vite.config.ts (the app this Customization Hub is cloned from),
// minus the Vitest block — this standalone app ships no test suite.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  build: {
    // Split the big auth/vendor deps out of the single app chunk so they cache
    // independently and the main bundle shrinks. Function form — robust to exact
    // pkg paths. Identical to csadmin.
    rollupOptions: {
      output: {
        manualChunks(id: string) {
          if (!id.includes("node_modules")) return undefined;
          if (/[\\/](firebase|@firebase)[\\/]/.test(id)) return "vendor-firebase";
          if (/[\\/](aws-amplify|@aws-amplify|amazon-cognito-identity-js)[\\/]/.test(id))
            return "vendor-aws";
          if (/[\\/](react|react-dom|react-router|react-router-dom|scheduler)[\\/]/.test(id))
            return "vendor-react";
          return "vendor";
        },
      },
    },
  },
});
