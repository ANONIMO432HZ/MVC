<?php

namespace App\Controllers\Admin;

use Core\Controller;
use App\Models\Admin\Categorias;
class ProductosController extends Controller

{
    protected $categoriasModel;

    public function __construct()
    {
        $this->categoriasModel = new Categorias();
    }

    public function index()
    {
        $this->view('admin/productos/index', [
            'is_Admin' => true,
            'module'    => 'admin',
            'pageTitle' => 'Productos'
        ]);
        exit;
    }
    public function nuevo()
    {
        $categorias = $this->categoriasModel->categorias_select();

        $this->view('admin/productos/nuevo', [
            'is_Admin' => true,
            'module'    => 'admin',
            'pageTitle' => 'Nuevo Producto',
            'categorias' => $categorias
        ]);
        exit;
    }
}
