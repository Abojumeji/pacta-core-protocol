export default function Hero() {
  return (
    <section className="relative min-h-screen flex items-center justify-center overflow-hidden grid-bg">
      {/* Background Gradient Orbs */}
      <div className="absolute top-1/4 left-1/4 w-[300px] sm:w-[600px] h-[300px] sm:h-[600px] bg-accent/10 rounded-full blur-[128px] pointer-events-none" />
      <div className="absolute bottom-1/4 right-1/4 w-[200px] sm:w-[400px] h-[200px] sm:h-[400px] bg-accent-secondary/10 rounded-full blur-[128px] pointer-events-none" />

      <div className="relative z-10 mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 pt-24 sm:pt-32 pb-12 sm:pb-20 text-center">
        {/* Badge */}
        <div className="animate-fade-in-up inline-flex items-center gap-2 rounded-full border border-accent/30 bg-accent/5 px-3 sm:px-4 py-1 sm:py-1.5 text-xs sm:text-sm text-accent mb-6 sm:mb-8">
          <span className="inline-block w-1.5 h-1.5 sm:w-2 sm:h-2 rounded-full bg-accent animate-pulse" />
          Deployed on Sui Testnet
        </div>

        {/* Headline */}
        <h1 className="animate-fade-in-up animation-delay-200 text-3xl sm:text-5xl md:text-6xl lg:text-7xl font-bold tracking-tight leading-[1.15] max-w-4xl mx-auto">
          The Settlement Layer for{" "}
          <span className="gradient-text">On-Chain Agreements</span>
        </h1>

        {/* Subheadline */}
        <p className="animate-fade-in-up animation-delay-400 mt-4 sm:mt-6 text-sm sm:text-lg md:text-xl text-text-muted max-w-2xl mx-auto leading-relaxed px-2">
          Pacta is trustless infrastructure for creating, escrowing, and settling
          any agreement on Sui. Condition-based. Asset-agnostic. Fully composable.
        </p>

        {/* CTAs */}
        <div className="animate-fade-in-up animation-delay-600 mt-8 sm:mt-10 flex flex-col sm:flex-row items-center justify-center gap-3 sm:gap-4">
          <a
            href="#developers"
            className="w-full sm:w-auto inline-flex items-center justify-center gap-2 rounded-xl bg-accent px-6 sm:px-8 py-3 sm:py-3.5 text-sm sm:text-base font-semibold text-white hover:bg-accent-secondary transition-all duration-200 hover:shadow-xl hover:shadow-accent/25 hover:-translate-y-0.5"
          >
            Build on Pacta
            <svg className="w-4 h-4 sm:w-5 sm:h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M13 7l5 5m0 0l-5 5m5-5H6" />
            </svg>
          </a>
          <a
            href="#how-it-works"
            className="w-full sm:w-auto inline-flex items-center justify-center gap-2 rounded-xl border border-border px-6 sm:px-8 py-3 sm:py-3.5 text-sm sm:text-base font-semibold text-foreground hover:bg-surface-light transition-all duration-200 hover:-translate-y-0.5"
          >
            How It Works
            <svg className="w-4 h-4 sm:w-5 sm:h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M19 9l-7 7-7-7" />
            </svg>
          </a>
        </div>

        {/* Milestone Pills */}
        <div className="animate-fade-in-up animation-delay-600 mt-6 flex flex-wrap items-center justify-center gap-3">
          <span className="inline-flex items-center gap-1.5 rounded-full border border-emerald-500/30 bg-emerald-500/5 px-3 py-1 text-xs text-emerald-400">
            <span className="w-1.5 h-1.5 rounded-full bg-emerald-400" />
            Testnet Live
          </span>
          <a href="https://github.com/Abojumeji/pacta-core-protocol" target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1.5 rounded-full border border-accent/30 bg-accent/5 px-3 py-1 text-xs text-accent hover:bg-accent/10 transition-colors">
            TypeScript SDK
          </a>
          <a href="https://pacta.mintlify.app" target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1.5 rounded-full border border-border px-3 py-1 text-xs text-text-muted hover:text-foreground transition-colors">
            Docs · pacta.mintlify.app
          </a>
          <a href="https://github.com/Abojumeji/pacta-core-protocol" target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1.5 rounded-full border border-border px-3 py-1 text-xs text-text-muted hover:text-foreground transition-colors">
            Open Source
          </a>
        </div>

        {/* Protocol Visual - Abstract State Machine */}
        <div className="mt-12 sm:mt-20 animate-fade-in-up animation-delay-600">
          <div className="relative mx-auto max-w-3xl">
            <div className="glow-accent rounded-xl sm:rounded-2xl border border-border/50 bg-surface/80 backdrop-blur-sm p-4 sm:p-8 md:p-12">
              {/* State Machine Visualization */}
              <div className="grid grid-cols-4 gap-2 sm:flex sm:flex-row sm:items-center sm:justify-between sm:gap-4 text-sm font-mono">
                {/* Create */}
                <div className="flex flex-col items-center gap-1.5 sm:gap-2">
                  <div className="w-10 h-10 sm:w-16 sm:h-16 rounded-lg sm:rounded-xl bg-accent/10 border border-accent/30 flex items-center justify-center">
                    <svg className="w-5 h-5 sm:w-7 sm:h-7 text-accent" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
                    </svg>
                  </div>
                  <span className="text-text-muted text-[10px] sm:text-xs">Create</span>
                </div>

                {/* Arrow - hidden on very small, shown inline on sm+ */}
                <div className="hidden sm:flex items-center">
                  <svg className="w-8 h-4 text-accent/50" fill="none" viewBox="0 0 32 16">
                    <path d="M0 8h28m0 0l-6-6m6 6l-6 6" stroke="currentColor" strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                </div>

                {/* Deposit */}
                <div className="flex flex-col items-center gap-1.5 sm:gap-2">
                  <div className="w-10 h-10 sm:w-16 sm:h-16 rounded-lg sm:rounded-xl bg-amber-500/10 border border-amber-500/30 flex items-center justify-center">
                    <svg className="w-5 h-5 sm:w-7 sm:h-7 text-amber-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z" />
                    </svg>
                  </div>
                  <span className="text-text-muted text-[10px] sm:text-xs">Deposit</span>
                </div>

                <div className="hidden sm:flex items-center">
                  <svg className="w-8 h-4 text-accent/50" fill="none" viewBox="0 0 32 16">
                    <path d="M0 8h28m0 0l-6-6m6 6l-6 6" stroke="currentColor" strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                </div>

                {/* Conditions */}
                <div className="flex flex-col items-center gap-1.5 sm:gap-2">
                  <div className="w-10 h-10 sm:w-16 sm:h-16 rounded-lg sm:rounded-xl bg-blue-500/10 border border-blue-500/30 flex items-center justify-center">
                    <svg className="w-5 h-5 sm:w-7 sm:h-7 text-blue-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z" />
                    </svg>
                  </div>
                  <span className="text-text-muted text-[10px] sm:text-xs">Conditions</span>
                </div>

                <div className="hidden sm:flex items-center">
                  <svg className="w-8 h-4 text-accent/50" fill="none" viewBox="0 0 32 16">
                    <path d="M0 8h28m0 0l-6-6m6 6l-6 6" stroke="currentColor" strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                </div>

                {/* Settled */}
                <div className="flex flex-col items-center gap-1.5 sm:gap-2">
                  <div className="w-10 h-10 sm:w-16 sm:h-16 rounded-lg sm:rounded-xl bg-emerald-500/10 border border-emerald-500/30 flex items-center justify-center">
                    <svg className="w-5 h-5 sm:w-7 sm:h-7 text-emerald-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                    </svg>
                  </div>
                  <span className="text-text-muted text-[10px] sm:text-xs">Settled</span>
                </div>
              </div>

              <p className="mt-4 sm:mt-6 text-text-muted text-[10px] sm:text-xs text-center font-mono">
                Trustless lifecycle: agreements settle automatically when all conditions are met
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
