"use client";

import { useState } from "react";
import { Header } from "@/components/Header";
import { SwapCard } from "@/components/SwapCard";
import { PoolCard } from "@/components/PoolCard";
import { BridgeCard } from "@/components/BridgeCard";
import { VaultCard } from "@/components/VaultCard";
import { FaucetCard } from "@/components/FaucetCard";
import { HistoryCard } from "@/components/HistoryCard";
import { StatsCard } from "@/components/StatsCard";

export default function Home() {
  const [activeTab, setActiveTab] = useState("swap");

  return (
    <div className="min-h-screen">
      <Header activeTab={activeTab} setActiveTab={setActiveTab} />

      <main className="flex flex-col items-center justify-center py-12 px-4">
        {/* Hero stats */}
        <div className="flex flex-wrap gap-6 mb-10 text-center justify-center">
          <Stat value="0.04%" label="Swap Fee" color="text-blue-400" />
          <Stat value="<1s" label="Finality" color="text-green-400" />
          <Stat value="~$0.01" label="Gas Cost" color="text-purple-400" />
          <Stat value="CCTP v2" label="Bridge" color="text-cyan-400" />
        </div>

        {/* Active page */}
        {activeTab === "swap" && <SwapCard />}
        {activeTab === "pool" && <PoolCard />}
        {activeTab === "bridge" && <BridgeCard />}
        {activeTab === "vault" && <VaultCard />}
        {activeTab === "faucet" && <FaucetCard />}
        {activeTab === "history" && <HistoryCard />}
        {activeTab === "stats" && <StatsCard />}

        {/* Footer */}
        <footer className="mt-12 text-center text-xs text-[#64748b] space-y-2">
          <p>
            ArcSwap DEX — Dual AMM (x*y=k + StableSwap) on{" "}
            <a
              href="https://testnet.arcscan.app"
              target="_blank" rel="noopener noreferrer"
              className="text-blue-400 hover:underline"
            >
              Arc Testnet
            </a>{" "}
            (Chain ID: 5042002)
          </p>
          <div className="flex gap-4 justify-center flex-wrap">
            <a
              href="https://testnet.arcscan.app/address/0x4c6B667a14Eb70F49D3C77f85b5Fc551A2e7CcBc"
              target="_blank" rel="noopener noreferrer"
              className="text-blue-400 hover:underline"
            >
              USDC/EURC (x*y=k)
            </a>
            <a
              href="https://testnet.arcscan.app/address/0x9baa830F14d43f76ddE073ACcB17D2B5a98ad0e2"
              target="_blank" rel="noopener noreferrer"
              className="text-blue-400 hover:underline"
            >
              USDC/USYC (StableSwap)
            </a>
            <a
              href="https://testnet.arcscan.app/address/0x2d667ad1BB962179072a33B6592de53f184D5187"
              target="_blank" rel="noopener noreferrer"
              className="text-blue-400 hover:underline"
            >
              MultiRouter v2
            </a>
          </div>
        </footer>
      </main>
    </div>
  );
}

function Stat({ value, label, color }: { value: string; label: string; color: string }) {
  return (
    <div>
      <div className={`text-2xl font-bold ${color}`}>{value}</div>
      <div className="text-sm text-[#94a3b8] mt-1">{label}</div>
    </div>
  );
}
