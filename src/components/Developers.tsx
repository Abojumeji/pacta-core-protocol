export default function Developers() {
  return (
    <section id="developers" className="relative py-16 sm:py-24 md:py-32 bg-surface/20">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div className="grid lg:grid-cols-2 gap-12 lg:gap-16 items-center">
          {/* Left - Content */}
          <div>
            <h2 className="text-sm font-semibold uppercase tracking-widest text-accent mb-4">
              For Developers
            </h2>
            <p className="text-3xl sm:text-4xl font-bold tracking-tight mb-6">
              Build on <span className="gradient-text">Pacta</span>
            </p>
            <p className="text-text-muted text-sm sm:text-lg leading-relaxed mb-6 sm:mb-8">
              Pacta v4 is built for protocol-to-protocol composability. The{" "}
              <code className="text-accent font-mono text-sm bg-accent/10 px-1.5 py-0.5 rounded">SettlementReceipt</code>{" "}
              hot potato lets you chain settlement into downstream PTB logic atomically.
              Agreement objects carry{" "}
              <code className="text-accent font-mono text-sm bg-accent/10 px-1.5 py-0.5 rounded">key + store</code>{" "}
              — wrap them, share them, or embed them in your own contracts.
            </p>

            <div className="space-y-4 mb-8">
              {[
                "create_agreement() — returns Agreement for wrapping or sharing",
                "deposit_coin<T>() / deposit_object<V>() — multi-asset escrow",
                "settle_with_receipt() — returns SettlementReceipt (hot potato)",
                "attach_hook<H>() / extract_hook_with_receipt<H>() — settlement hooks",
                "set_party_b() — fill open agreements (listing / RFQ patterns)",
                "conclude_dispute() — per-asset arbiter resolution, STATE_DISPUTE_RESOLVED",
                "PactaRegistry — on-chain protocol stats (settled, cancelled, disputed)",
              ].map((item, i) => (
                <div key={i} className="flex items-start gap-3">
                  <svg className="w-5 h-5 text-emerald-400 shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
                  </svg>
                  <span className="text-sm text-text-muted font-mono">{item}</span>
                </div>
              ))}
            </div>

            <div className="flex flex-wrap gap-4">
              <a
                href="https://pacta.mintlify.app"
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-2 rounded-xl bg-accent px-6 py-3 text-sm font-semibold text-white hover:bg-accent-secondary transition-all hover:shadow-lg hover:shadow-accent/25"
              >
                Read the Docs
                <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M13 7l5 5m0 0l-5 5m5-5H6" />
                </svg>
              </a>
              <a
                href="https://github.com/Abojumeji/pacta-core-protocol"
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-2 rounded-xl border border-border px-6 py-3 text-sm font-semibold text-foreground hover:bg-surface-light transition-all"
              >
                <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                  <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
                </svg>
                View on GitHub
              </a>
              <a
                href="https://github.com/Abojumeji/pacta-core-protocol"
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-2 rounded-xl border border-accent/30 bg-accent/5 px-6 py-3 text-sm font-semibold text-accent hover:bg-accent/10 transition-all"
              >
                TypeScript SDK
              </a>
            </div>
          </div>

          {/* Right - Code Snippet */}
          <div className="relative">
            <div className="glow-accent rounded-2xl overflow-hidden">
              <div className="flex items-center gap-2 px-5 py-3 bg-surface border-b border-border/50">
                <div className="w-3 h-3 rounded-full bg-red-500/60" />
                <div className="w-3 h-3 rounded-full bg-yellow-500/60" />
                <div className="w-3 h-3 rounded-full bg-green-500/60" />
                <span className="ml-3 text-xs text-text-muted font-mono">pacta.move</span>
              </div>
              <div className="bg-[#0d1117] p-3 sm:p-6 overflow-x-auto">
                <pre className="text-[11px] sm:text-sm font-mono leading-relaxed">
                  <code>
                    <span className="text-purple-400">{"/// v4: Open agreement — any taker can fill"}</span>{"\n"}
                    <span className="text-blue-400">let mut</span> agr = <span className="text-yellow-300">create_agreement</span>{"("}{"\n"}
                    {"    "}party_a: <span className="text-emerald-400">@maker</span>,{"\n"}
                    {"    "}party_b: <span className="text-emerald-400">@0x0</span>,{"  "}<span className="text-purple-400">{"// open slot"}</span>{"\n"}
                    {"    "}release_conditions: <span className="text-orange-400">3</span>,{"  "}<span className="text-purple-400">{"// A|B deposited"}</span>{"\n"}
                    {"    "}clock, ctx,{"\n"}
                    {");"}{"\n\n"}
                    <span className="text-purple-400">{"/// Attach a settlement hook"}</span>{"\n"}
                    <span className="text-yellow-300">attach_hook</span>{"("}&<span className="text-blue-400">mut</span> agr,{"\n"}
                    {"    "}NotifyHook {"{"} target: <span className="text-emerald-400">@oracle</span> {"}"}, ctx{"\n"}
                    {");"}{"\n\n"}
                    <span className="text-purple-400">{"/// Taker fills the open slot"}</span>{"\n"}
                    <span className="text-yellow-300">set_party_b</span>{"("}&<span className="text-blue-400">mut</span> agr, ctx{")"};{"\n\n"}
                    <span className="text-purple-400">{"/// Both deposit → conditions met"}</span>{"\n"}
                    <span className="text-purple-400">{"/// settle_with_receipt() returns hot potato"}</span>{"\n"}
                    <span className="text-blue-400">let</span> receipt = <span className="text-yellow-300">settle_with_receipt</span>{"("}{"\n"}
                    {"    "}&<span className="text-blue-400">mut</span> agr, clock, ctx{"\n"}
                    {");"}{"\n\n"}
                    <span className="text-purple-400">{"/// Chain into downstream PTB — atomically"}</span>{"\n"}
                    oracle::<span className="text-yellow-300">on_settle</span>{"("}{"\n"}
                    {"    "}<span className="text-yellow-300">extract_hook_with_receipt</span>{"<"}NotifyHook{">"}{"("}{"\n"}
                    {"        "}&<span className="text-blue-400">mut</span> agr, receipt, ctx{")"},{"\n"}
                    {"    "}&<span className="text-blue-400">mut</span> oracle_state, ctx{"\n"}
                    {")"};{"  "}<span className="text-purple-400">{"// receipt consumed ✓"}</span>
                  </code>
                </pre>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
