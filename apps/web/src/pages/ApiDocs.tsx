import { useEffect } from "react";
import ReactMarkdown from "react-markdown";
import apiContract from "../../../../docs/api-contract.md?raw";
import { BrandLockup } from "../components/Brand";

export function ApiDocsPage() {
  useEffect(() => {
    const previousTitle = document.title;
    document.title = "API Documentation — Halation";
    return () => {
      document.title = previousTitle;
    };
  }, []);

  return (
    <div className="api-docs-page">
      <header className="api-docs-header">
        <BrandLockup tagline="API documentation" href="/" />
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
