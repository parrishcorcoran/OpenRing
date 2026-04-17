export const metadata = {
  title: "OpenRing",
  description: "Live peek at an OpenRing loop.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", background: "#0b0b0c", color: "#e6e6e6", margin: 0 }}>
        {children}
      </body>
    </html>
  );
}
