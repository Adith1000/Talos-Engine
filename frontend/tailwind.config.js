/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      fontFamily: {
        mono: ['"JetBrains Mono"', "ui-monospace", "monospace"],
        display: ['"Archivo"', "system-ui", "sans-serif"],
      },
      colors: {
        ink: {
          900: "#0a0c10", // app background
          800: "#0f1217", // panels
          700: "#161a21", // cards
          600: "#1d222b", // raised
          500: "#272d39", // borders
        },
        signal: {
          DEFAULT: "#ff7a18", // primary accent (wiring orange)
          soft: "#ffb070",
        },
        // category accents
        cat: {
          checkout: "#38bdf8",
          setup: "#a78bfa",
          install: "#2dd4bf",
          test: "#f5a524",
          build: "#94a3b8",
          deploy: "#34d399",
        },
      },
      boxShadow: {
        node: "0 1px 0 rgba(255,255,255,0.03) inset, 0 8px 24px -12px rgba(0,0,0,0.8)",
      },
    },
  },
  plugins: [],
};