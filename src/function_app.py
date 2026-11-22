"""Azure Functions entry point (Python v2 programming model)."""
import azure.functions as func

from collector import run_cycle

app = func.FunctionApp()


@app.timer_trigger(schedule="0 */5 * * * *", arg_name="timer",
                   run_on_startup=False, use_monitor=True)
def collect_evidence(timer: func.TimerRequest) -> None:
    """R4: runs every 5 minutes (NCRONTAB, UTC)."""
    run_cycle()
