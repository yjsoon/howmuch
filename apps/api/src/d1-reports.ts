import { PostgresReportService } from "./postgres-reports";
import { D1Database, type D1Binding } from "./d1";

/** SQLite-report implementation over D1's asynchronous API. */
export class D1ReportService extends PostgresReportService {
  constructor(binding: D1Binding) {
    super(new D1Database(binding), "sqlite");
  }
}
