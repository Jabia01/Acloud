import type { ReactNode } from 'react';
import './styles.css';

export const dynamic = 'force-dynamic';
export const metadata = {title: {default: 'Acloud — A home for your memories', template: '%s | Acloud'}, description: 'Private photo and video backup. Keep a protected copy while your originals stay on your device.'};

export default function RootLayout({ children }: { children: ReactNode }) {
  return <html lang="en"><body>{children}</body></html>;
}
