"use client";

import { useState, useEffect } from "react";
import Image from "next/image";
import pactaLogo from "@/assets/pacta-logo.jpeg";

const navLinks = [
  { label: "Features", href: "#features" },
  { label: "How It Works", href: "#how-it-works" },
  { label: "Use Cases", href: "#use-cases" },
  { label: "Ecosystem", href: "#ecosystem" },
  { label: "Developers", href: "#developers" },
];

export default function Navbar() {
  const [mobileOpen, setMobileOpen] = useState(false);

  // Prevent body scroll when mobile menu is open
  useEffect(() => {
    if (mobileOpen) {
      document.body.style.overflow = "hidden";
    } else {
      document.body.style.overflow = "";
    }
    return () => {
      document.body.style.overflow = "";
    };
  }, [mobileOpen]);

  return (
    <nav className="fixed top-0 left-0 right-0 z-50 border-b border-border/50 bg-background/80 backdrop-blur-xl">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div className="flex h-14 sm:h-16 items-center justify-between">
          {/* Logo */}
          <a href="#" className="flex items-center gap-2 sm:gap-3">
            <Image
              src={pactaLogo}
              alt="Pacta"
              width={30}
              height={30}
              className="rounded-lg sm:w-9 sm:h-9"
            />
            <span className="text-lg sm:text-xl font-bold tracking-tight">Pacta</span>
          </a>

          {/* Desktop Nav */}
          <div className="hidden md:flex items-center gap-8">
            {navLinks.map((link) => (
              <a
                key={link.href}
                href={link.href}
                className="text-sm text-text-muted hover:text-foreground transition-colors duration-200"
              >
                {link.label}
              </a>
            ))}
          </div>

          {/* Desktop CTAs */}
          <div className="hidden md:flex items-center gap-4">
            <a
              href="https://pacta.mintlify.app"
              target="_blank"
              rel="noopener noreferrer"
              className="text-sm text-text-muted hover:text-foreground transition-colors"
            >
              Docs
            </a>
            <a
              href="#developers"
              className="inline-flex items-center gap-2 rounded-lg bg-accent px-5 py-2.5 text-sm font-semibold text-white hover:bg-accent-secondary transition-all duration-200 hover:shadow-lg hover:shadow-accent/25"
            >
              Build on Pacta
              <svg
                className="w-4 h-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                strokeWidth={2}
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  d="M13 7l5 5m0 0l-5 5m5-5H6"
                />
              </svg>
            </a>
          </div>

          {/* Mobile Toggle */}
          <button
            onClick={() => setMobileOpen(!mobileOpen)}
            className="md:hidden text-text-muted hover:text-foreground p-1"
            aria-label="Toggle menu"
          >
            {mobileOpen ? (
              <svg className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            ) : (
              <svg className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16M4 12h16M4 18h16" />
              </svg>
            )}
          </button>
        </div>
      </div>

      {/* Mobile Menu - Full screen overlay */}
      {mobileOpen && (
        <div className="md:hidden fixed inset-0 top-14 z-40 bg-background/95 backdrop-blur-lg">
          <div className="px-4 py-6 space-y-1">
            {navLinks.map((link) => (
              <a
                key={link.href}
                href={link.href}
                onClick={() => setMobileOpen(false)}
                className="block text-base text-text-muted hover:text-foreground transition-colors py-3 border-b border-border/30"
              >
                {link.label}
              </a>
            ))}
            <div className="pt-4 space-y-3">
              <a
                href="https://pacta.mintlify.app"
                target="_blank"
                rel="noopener noreferrer"
                onClick={() => setMobileOpen(false)}
                className="block text-base text-text-muted hover:text-foreground transition-colors py-3"
              >
                Docs
              </a>
              <a
                href="#developers"
                onClick={() => setMobileOpen(false)}
                className="block w-full text-center rounded-lg bg-accent px-5 py-3 text-sm font-semibold text-white"
              >
                Build on Pacta
              </a>
            </div>
          </div>
        </div>
      )}
    </nav>
  );
}
