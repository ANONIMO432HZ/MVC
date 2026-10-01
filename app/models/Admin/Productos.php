<?php

namespace App\Models\Admin;

use Core\Model;
use PDO;

class Productos extends Model
{
    protected $table = 'productos';
    public function registrar($data)
    {
        $sql = "INSERT INTO {$this->table} (categoria_id, codigo_sku, nombre, descripcion, precio_venta, stock_actual) VALUES (:categoria_id, :codigo_sku, :nombre, :descripcion, :precio_venta, :stock_actual)";
        $params = [
            ':categoria_id' => $data['categoria_id'],
            ':codigo_sku' => $data['codigo_sku'],
            ':nombre' => $data['nombre'],
            ':descripcion' => $data['descripcion'],
            ':precio_venta' => $data['precio_venta'],
            ':stock_actual' => $data['stock_actual']
        ];
        $stmt = self::$db->prepare($sql);
        return $stmt->execute($params);
    }
    public function buscar() {}
    public function ver() {}
    public function actualizar() {}
    public function eliminar() {}
}
