import React from 'react';
import { Img, staticFile } from 'remotion';

interface AppIconProps {
  size: number;
  /**
   * Optional clipping for compositions that place the app icon on a hard-edged
   * surface. The source asset already carries transparent macOS icon corners.
   */
  rounded?: boolean;
  /**
   * Soft drop-shadow under the icon, matching how dock icons sit on light
   * backgrounds. Off by default — most compositions don't want this.
   */
  shadow?: boolean;
}

/**
 * The MacParakeet macOS app icon — white calligraphic parakeet on near-black,
 * padded into a transparent 1024×1024 icon source (`Assets/AppIcon-1024x1024.png`
 * in the main repo, mirrored into `public/brand/app-icon.png` here).
 *
 * Use AppIcon when you want the product to look like a Mac app the viewer is
 * about to install (closing cards, product feature beats), and use the
 * canonical line mark for chrome / wordmark contexts where the bird is one
 * symbol among type.
 */
export const AppIcon: React.FC<AppIconProps> = ({
  size,
  rounded = true,
  shadow = false,
}) => {
  return (
    <Img
      src={staticFile('brand/app-icon.png')}
      style={{
        width: size,
        height: size,
        borderRadius: rounded ? size * 0.22 : 0,
        display: 'block',
        boxShadow: shadow
          ? `0 ${size * 0.04}px ${size * 0.08}px rgba(14, 15, 18, 0.18)`
          : 'none',
      }}
    />
  );
};
