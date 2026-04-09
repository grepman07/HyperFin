import fs from 'fs';
import path from 'path';

export interface TelemetryEventRow {
  id: string;
  installId: string;
  sessionId: string;
  timestamp: string;
  queryAnon: string;
  responseAnon: string;
  intent: string;
  category: string | null;
  period: string | null;
  latencyMs: number;
  modelVersion: string;
  appVersion: string;
  feedback: string | null;
  receivedAt: string;
}

/**
 * Minimal append-only JSONL sink. One file per day, rotated by filename.
 * Swappable for S3 / BigQuery / Postgres later without touching the route.
 */
export interface TelemetrySink {
  write(events: TelemetryEventRow[]): Promise<void>;
  deleteByInstallId(installId: string): Promise<number>;
}

export class JsonlTelemetrySink implements TelemetrySink {
  constructor(private baseDir: string) {
    if (!fs.existsSync(baseDir)) {
      fs.mkdirSync(baseDir, { recursive: true });
    }
  }

  private currentFile(): string {
    const date = new Date().toISOString().slice(0, 10);
    return path.join(this.baseDir, `telemetry-${date}.jsonl`);
  }

  async write(events: TelemetryEventRow[]): Promise<void> {
    if (events.length === 0) return;
    const lines = events.map((e) => JSON.stringify(e)).join('\n') + '\n';
    await fs.promises.appendFile(this.currentFile(), lines, { encoding: 'utf8' });
  }

  async deleteByInstallId(installId: string): Promise<number> {
    // Walk every JSONL file, rewrite without matching rows.
    let removed = 0;
    const files = await fs.promises.readdir(this.baseDir).catch(() => []);
    for (const file of files) {
      if (!file.startsWith('telemetry-') || !file.endsWith('.jsonl')) continue;
      const fullPath = path.join(this.baseDir, file);
      const content = await fs.promises.readFile(fullPath, 'utf8');
      const kept: string[] = [];
      for (const line of content.split('\n')) {
        if (!line.trim()) continue;
        try {
          const row = JSON.parse(line) as TelemetryEventRow;
          if (row.installId === installId) {
            removed += 1;
          } else {
            kept.push(line);
          }
        } catch {
          // Preserve unparseable lines — something else wrote them
          kept.push(line);
        }
      }
      await fs.promises.writeFile(fullPath, kept.length ? kept.join('\n') + '\n' : '', 'utf8');
    }
    return removed;
  }
}

// Default singleton used by the route
const DEFAULT_DIR = process.env.TELEMETRY_DIR || path.join(process.cwd(), 'telemetry-data');
export const defaultTelemetrySink: TelemetrySink = new JsonlTelemetrySink(DEFAULT_DIR);
