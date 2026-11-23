import { createContext, useContext, useMemo, useState, type ReactNode } from "react";

interface PanelState {
  host: HTMLDivElement | null;
  setHost: (node: HTMLDivElement | null) => void;
  open: boolean;
  setOpen: (open: boolean) => void;
}

const PanelContext = createContext<PanelState>({
  host: null,
  setHost: () => {},
  open: false,
  setOpen: () => {},
});

// Wraps the main content and adds a right-hand detail panel that pushes the
// content instead of covering it.
export function PanelHost({ children }: { children: ReactNode }) {
  const [host, setHost] = useState<HTMLDivElement | null>(null);
  const [open, setOpen] = useState(false);
  const value = useMemo(() => ({ host, setHost, open, setOpen }), [host, open]);

  return (
    <PanelContext.Provider value={value}>
      <div className={`workspace${open ? " panel-open" : ""}`}>
        {children}
        <aside className="detail-panel" aria-hidden={!open}>
          <div className="detail-panel-host" ref={setHost} />
        </aside>
      </div>
    </PanelContext.Provider>
  );
}

export function usePanel() {
  return useContext(PanelContext);
}