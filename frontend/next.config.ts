import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "export",
  basePath: "/ArcSwap-V2",
  images: { unoptimized: true },
};

export default nextConfig;
