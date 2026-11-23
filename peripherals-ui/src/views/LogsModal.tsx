import { Modal } from "../components";
import LogViewer from "./LogViewer";

export default function LogsModal({
  title,
  unit,
  onClose,
}: {
  title: string;
  unit: string | null;
  onClose: () => void;
}) {
  return (
    <Modal title={title} onClose={onClose} wide>
      <LogViewer unit={unit} compact />
    </Modal>
  );
}