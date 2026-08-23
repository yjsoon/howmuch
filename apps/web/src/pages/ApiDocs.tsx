import { useEffect } from "react";
import ReactMarkdown from "react-markdown";
import apiContract from "../../../../docs/api-contract.md?raw";

export function ApiDocsPage() {
  useEffect(() => {
    const previousTitle = document.title;
    document.title = "API Documentation — HowMuch";
    return () => {
      document.title = previousTitle;
    };
  }, []);

  return (
    <div className="api-docs-page">
      <header className="api-docs-header">
        <a className="api-docs-brand" href="/">
          <span className="brand-mark" aria-hidden="true">H</span>
          <span>
            <strong>HowMuch</strong>
            <small>API documentation</small>
          </span>
        </a>
        <a
          className="api-docs-source"
          href="https://github.com/yjsoon/howmuch/blob/main/docs/api-contract.md"
        >
          View source
        </a>
      </header>
      <main className="api-docs-content">
        <ReactMarkdown>{apiContract}</ReactMarkdown>
      </main>
    </div>
  );
}
