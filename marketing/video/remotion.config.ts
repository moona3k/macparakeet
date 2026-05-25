import { Config } from '@remotion/cli/config';

// Highest-quality defaults. Override per-composition in CLI flags when needed.
Config.setVideoImageFormat('jpeg');
Config.setJpegQuality(95);
Config.setPixelFormat('yuv420p');
Config.setCodec('h264');
Config.setCrf(16); // visually lossless target
Config.setOverwriteOutput(true);
Config.setConcurrency(null); // auto (uses all cores)
Config.setChromiumOpenGlRenderer('angle');
