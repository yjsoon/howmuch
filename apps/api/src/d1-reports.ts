import { AsyncReportService } from "./async-reports";
import { D1Database, type D1Binding } from "./d1";

/** SQLite-report implementation over D1's asynchronous API. */
export class D1ReportService extends AsyncReportService {
  constructor(binding: D1Binding) {
    super(new D1Database(binding));
  }
}
