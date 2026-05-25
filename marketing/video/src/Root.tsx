import React from 'react';
import { Composition, Still } from 'remotion';
import { BrandShow15Portrait } from './compositions/BrandShow15Portrait';
import { BrandShow30 } from './compositions/BrandShow30';
import { Demo60 } from './compositions/Demo60';
import { HeroLoop30 } from './compositions/HeroLoop30';
import { Hook } from './compositions/Hook';
import { KeyArt } from './compositions/KeyArt';

const FPS = 60;

export const Root: React.FC = () => {
  return (
    <>
      {/* ─── Hook · 5s · 1920×1080 ───────────────────────────────────── */}
      <Composition
        id="Hook"
        component={Hook}
        durationInFrames={FPS * 5}
        fps={FPS}
        width={1920}
        height={1080}
      />

      {/* ─── BrandShow30 · 30s · 1920×1080 ───────────────────────────── */}
      {/* Pop Warhol brand film. Pass audioReady once music files exist. */}
      <Composition
        id="BrandShow30"
        component={BrandShow30}
        durationInFrames={FPS * 30}
        fps={FPS}
        width={1920}
        height={1080}
        defaultProps={{ audioReady: false }}
      />

      {/* ─── BrandShow15Portrait · 15s · 1080×1920 (Reels / TikTok) ──── */}
      <Composition
        id="BrandShow15Portrait"
        component={BrandShow15Portrait}
        durationInFrames={FPS * 15}
        fps={FPS}
        width={1080}
        height={1920}
        defaultProps={{ audioReady: false }}
      />

      {/* ─── HeroLoop30 · 30s · silent autoplay hero ─────────────────── */}
      <Composition
        id="HeroLoop30"
        component={HeroLoop30}
        durationInFrames={FPS * 30}
        fps={FPS}
        width={1920}
        height={1080}
      />

      {/* ─── Demo60 · 60s · explainer with VO ────────────────────────── */}
      <Composition
        id="Demo60"
        component={Demo60}
        durationInFrames={FPS * 60}
        fps={FPS}
        width={1920}
        height={1080}
      />

      {/* ─── KeyArt · static still · 1200×1600 portrait ──────────────── */}
      <Still
        id="KeyArt"
        component={KeyArt}
        width={1200}
        height={1600}
      />
    </>
  );
};
