declare module "chrome-remote-interface" {
  interface CDPClient {
    close?: () => void;
    on(event: string, listener: (...args: any[]) => void): void;
    off(event: string, listener: (...args: any[]) => void): void;
    send(method: string, params?: Record<string, unknown>): Promise<any>;
  }
  function CDP(options: { target: string }): Promise<CDPClient>;
  namespace CDP {
    interface CDPTarget {
      type: string;
      url: string;
      webSocketDebuggerUrl?: string;
    }
    function List(options: { port: number }): Promise<CDPTarget[]>;
  }
  export = CDP;
}
