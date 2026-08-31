'use strict';

const fs = require('fs');
const path = require('path');

function fail(message) {
  throw new Error(`Workspace Widget semantic icon build failed: ${message}`);
}

async function main() {
  let sharp;
  try {
    sharp = require('sharp');
  } catch (error) {
    fail(
      'the sharp module is required to render the committed PNG assets. ' +
      'Set NODE_PATH to a trusted development dependency directory before running this script.'
    );
  }

  const projectRoot = path.resolve(__dirname, '..');
  const iconRoot = path.join(projectRoot, 'assets', 'semantic-icons');
  const manifestPath = path.join(iconRoot, 'manifest.json');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const expectedIds = [
    'launch',
    'service',
    'people',
    'workspace',
    'web',
    'data',
    'automation',
    'lab'
  ];

  if (manifest.schemaVersion !== 1) fail('unsupported manifest schema.');
  if (manifest.provenance?.type !== 'original-work') fail('original-work provenance is required.');
  if (!Array.isArray(manifest.icons) || manifest.icons.length !== expectedIds.length) {
    fail(`the manifest must contain exactly ${expectedIds.length} icons.`);
  }

  const seenIds = new Set();
  for (const icon of manifest.icons) {
    if (!expectedIds.includes(icon.id) || seenIds.has(icon.id)) {
      fail(`invalid or duplicate icon id '${icon.id}'.`);
    }
    seenIds.add(icon.id);
    if (icon.svg !== `${icon.id}.svg` || icon.png !== `${icon.id}.png`) {
      fail(`icon '${icon.id}' must use canonical filenames.`);
    }

    const svgPath = path.join(iconRoot, icon.svg);
    const pngPath = path.join(iconRoot, icon.png);
    const svg = fs.readFileSync(svgPath, 'utf8');
    const prohibited = /<(?:script|image|foreignObject|style)\b|(?:href|xlink:href|on\w+)\s*=|url\s*\(/i;
    if (prohibited.test(svg)) fail(`icon '${icon.id}' contains prohibited SVG content.`);
    if (!/viewBox="0 0 24 24"/.test(svg)) fail(`icon '${icon.id}' has the wrong viewBox.`);
    if (!/fill="none"/.test(svg) || !/stroke="currentColor"/.test(svg)) {
      fail(`icon '${icon.id}' must remain a transparent currentColor line icon.`);
    }
    if (!/stroke-width="1\.75"/.test(svg)) fail(`icon '${icon.id}' has the wrong stroke width.`);

    const rasterSvg = svg.replace(
      '<svg ',
      `<svg color="${manifest.geometry.rasterForeground}" `
    );
    await sharp(Buffer.from(rasterSvg))
      .resize(manifest.geometry.rasterSize, manifest.geometry.rasterSize, {
        fit: 'contain',
        kernel: sharp.kernel.lanczos3
      })
      .png({ compressionLevel: 9, adaptiveFiltering: true })
      .toFile(pngPath);
  }

  process.stdout.write(JSON.stringify({
    success: true,
    iconCount: manifest.icons.length,
    rasterSize: manifest.geometry.rasterSize,
    outputRoot: iconRoot
  }, null, 2) + '\n');
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
