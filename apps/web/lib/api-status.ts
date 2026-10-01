import { isHealthy } from '@backup/shared';

export async function getApiStatus(baseUrl: string, fetcher: typeof fetch = fetch): Promise<'Connected' | 'Unavailable'> {
  try {
    const response = await fetcher(new URL('/health', baseUrl), {
      cache: 'no-store', signal: AbortSignal.timeout(3500), redirect: 'error',
    });
    return response.ok && isHealthy(await response.json()) ? 'Connected' : 'Unavailable';
  } catch {
    return 'Unavailable';
  }
}
