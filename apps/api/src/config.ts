export type ApiConfig = {
  dbPath: string;
  port: number;
  apiToken?: string;
  defaultPlanId: string;
};

export function loadConfig(env: Record<string, string | undefined> = Bun.env): ApiConfig {
  return {
    dbPath: env.HOWMUCH_DB_PATH ?? "data/howmuch.sqlite",
    port: Number(env.PORT ?? env.HOWMUCH_PORT ?? "8787"),
    apiToken: env.HOWMUCH_API_TOKEN,
    defaultPlanId: env.HOWMUCH_DEFAULT_PLAN_ID ?? "local-plan",
  };
}

